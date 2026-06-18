import 'dart:async';

import 'package:broadcast_queue_shim_for_ndk/broadcast_queue_shim_for_ndk.dart';
import 'package:ndk/ndk.dart';
import 'package:sembast/sembast.dart' show Database;

import 'address_book_store.dart';
import 'nostr_address_book_exception.dart';
import 'nostr_address_book_models.dart';
import 'vcard_tools.dart';

class NostrAddressBook {
  /// Nostr kind used for addressable encrypted vCard contact events.
  static const int contactKind = 38522;

  /// NIP-09 deletion event kind.
  static const int deletionKind = 5;

  /// Default number of newest contact/deletion events fetched by [fetchRecent].
  static const int recentLimit = 500;

  /// NDK instance used for accounts, Nostr queries, broadcasts, and cache access.
  final Ndk ndk;

  /// Sembast database used for address-book raw decrypted data, computed data,
  /// and the offline broadcast queue.
  final Database database;
  final AddressBookStore _store;

  /// Offline-first broadcast queue used to eventually publish contact and
  /// deletion events.
  ///
  /// Callers may use this directly for retry/status workflows, for example
  /// [OfflineBroadcast.retryNow], [OfflineBroadcast.start], or
  /// [OfflineBroadcast.watchPending].
  final OfflineBroadcast broadcastQueue;

  /// Creates an address book backed by [ndk] and [database].
  ///
  /// The constructor does not require a signer or relay list. Signing and
  /// NIP-44 self-encryption use the current account in `ndk.accounts`; relay
  /// selection is derived from NDK when events are queued for broadcast.
  NostrAddressBook({required this.ndk, required this.database})
    : _store = AddressBookStore(database),
      broadcastQueue = OfflineBroadcast.withNdk(ndk, db: database);

  /// Fetches the newest address-book contact and deletion events.
  ///
  /// This is intended as a quick startup refresh. It queries contacts and
  /// NIP-09 deletions with [recentLimit] and does not paginate. Queries are
  /// sent explicitly to [getReadRelays].
  Future<AddressBookSyncResult> fetchRecent() {
    return _fetch(
      contactFilter: contactFilter(limit: recentLimit),
      deletionFilter: deletionFilter(limit: recentLimit),
      paginate: false,
    );
  }

  /// Returns the relay URLs used for reading address-book events.
  ///
  /// The list comes from the current account NIP-65 read relays through
  /// `ndk.userRelayLists`. If no read relay is available, the method falls
  /// back explicitly to currently connected relays, then NDK bootstrap relays.
  Future<List<String>> getReadRelays({bool forceRefresh = false}) async {
    final pubkey = _requirePubkey();
    final userRelayList = await ndk.userRelayLists.getSingleUserRelayList(
      pubkey,
      forceRefresh: forceRefresh,
    );
    return _relayFallback(userRelayList?.readUrls ?? const []);
  }

  /// Returns the relay URLs used for publishing address-book events.
  ///
  /// The list comes from the current account NIP-65 write relays through
  /// `ndk.userRelayLists`. If no write relay is available, the method falls
  /// back explicitly to currently connected relays, then NDK bootstrap relays.
  Future<List<String>> getWriteRelays({bool forceRefresh = false}) async {
    final pubkey = _requirePubkey();
    final userRelayList = await ndk.userRelayLists.getSingleUserRelayList(
      pubkey,
      forceRefresh: forceRefresh,
    );
    return _relayFallback(userRelayList?.writeUrls ?? const []);
  }

  Future<AddressBookSyncResult> pull({
    bool paginate = true,
    int? since,
    int? until,
  }) {
    return _fetch(
      contactFilter: contactFilter(since: since, until: until),
      deletionFilter: deletionFilter(since: since, until: until),
      paginate: paginate,
      useFetchedRanges: since != null || until != null,
    );
  }

  /// Saves or updates a contact from a vCard 4.0 text payload.
  ///
  /// This method is local-first:
  ///
  /// - validates that [vCardText] contains a single vCard 4.0 object;
  /// - generates a UUID-based `UID` when the vCard has none;
  /// - creates a Nostr addressable event of kind [contactKind] with `d = UID`;
  /// - NIP-44 self-encrypts the vCard using the current `ndk.accounts` signer;
  /// - saves the encrypted event into the NDK cache;
  /// - saves `eventId -> decrypted vCard text` in the raw local store;
  /// - rebuilds the computed contact stores;
  /// - queues the event in [broadcastQueue] for eventual relay delivery.
  ///
  /// The returned [AddressBookContact] is the local computed contact. It does
  /// not mean relays have acknowledged the event yet; inspect [broadcastQueue]
  /// for delivery status.
  ///
  /// Throws [AddressBookAccountException] if no signing account is logged in,
  /// [AddressBookVCardException] if the vCard is invalid, or
  /// [AddressBookCryptoException] if NIP-44 encryption fails.
  Future<AddressBookContact> upsertVCard(String vCardText) async {
    final account = _requireSigningAccount();
    final canonical = VCardTools.parseAndNormalize(vCardText);
    final encrypted = await account.signer.encryptNip44(
      plaintext: canonical.text,
      recipientPubKey: account.pubkey,
    );
    if (encrypted == null) {
      throw const AddressBookCryptoException('NIP-44 encryption failed');
    }

    final now = Nip01Event.secondsSinceEpoch();
    final event = Nip01Event(
      pubKey: account.pubkey,
      kind: contactKind,
      tags: [
        ['d', canonical.uid],
      ],
      content: encrypted,
      createdAt: now,
    );

    await ndk.config.cache.saveEvent(event);
    await _store.saveDecryptedEvent(event.id, canonical.text);
    await rebuildComputedStores();

    final relays = await getWriteRelays();
    if (relays.isNotEmpty) {
      await broadcastQueue.broadcast(event, relays: relays);
    }

    final contact = await get(canonical.uid);
    if (contact == null) {
      throw const NostrAddressBookException('Contact was not materialized');
    }
    return contact;
  }

  /// Deletes the local contact with [uid] by queuing a NIP-09 deletion event.
  ///
  /// The deletion event targets the latest known contact event. The computed
  /// contact is marked deleted locally after the deletion event is saved to the
  /// NDK cache; relay delivery remains the responsibility of [broadcastQueue].
  Future<void> delete(String uid, {String reason = 'delete'}) async {
    final account = _requireSigningAccount();
    final contact = await get(uid);
    if (contact == null || contact.deleted) return;

    final now = Nip01Event.secondsSinceEpoch();
    final event = Nip01Event(
      pubKey: account.pubkey,
      kind: deletionKind,
      tags: [
        ['e', contact.eventId],
        ['a', '$contactKind:${account.pubkey}:$uid'],
        ['k', contactKind.toString()],
      ],
      content: reason,
      createdAt: now,
    );
    await ndk.config.cache.saveEvent(event);

    final relays = await getWriteRelays();
    if (relays.isNotEmpty) {
      await broadcastQueue.broadcast(event, relays: relays);
    }
    await rebuildComputedStores();
  }

  /// Returns the local computed contact for [uid], or `null` if absent.
  Future<AddressBookContact?> get(String uid) => _store.getContact(uid);

  /// Lists local computed contacts.
  ///
  /// This reads only Sembast computed stores and does not require internet or a
  /// signer.
  Future<List<AddressBookContact>> list({ContactQuery? query}) {
    return _store.list(query: query);
  }

  /// Watches local computed contacts.
  ///
  /// This is a Sembast watcher, not an NDK network subscription.
  Stream<List<AddressBookContact>> watchAll({ContactQuery? query}) {
    return _store.watchAll(query: query);
  }

  /// Watches a single local computed contact by [uid].
  ///
  /// This is a Sembast watcher, not an NDK network subscription.
  Stream<AddressBookContact?> watch(String uid) {
    return _store.watch(uid);
  }

  /// Drops and rebuilds all computed address-book stores.
  ///
  /// Rebuild uses only the NDK cache and the raw
  /// `address_book_decrypted_events` store, so it works without internet and
  /// without a signer. Raw decrypted entries whose encrypted NDK event is no
  /// longer present are ignored.
  Future<int> rebuildComputedStores() async {
    final decryptedEvents = await _store.loadAllDecryptedEvents();
    final candidates = <_ContactCandidate>[];
    final uidEvents = <String, List<String>>{};

    for (final entry in decryptedEvents.entries) {
      final event = await ndk.config.cache.loadEvent(entry.key);
      if (event == null || event.kind != contactKind) continue;
      final uid = event.getDtag();
      if (uid == null || uid.isEmpty) continue;
      try {
        final canonical = VCardTools.parseExisting(entry.value);
        if (canonical.uid != uid) continue;
        candidates.add(_ContactCandidate(event: event, card: canonical));
        uidEvents.putIfAbsent(uid, () => []).add(event.id);
      } on NostrAddressBookException {
        continue;
      }
    }

    final deletions = await _loadDeletionTimes(
      knownEventIds: candidates.map((candidate) => candidate.event.id).toSet(),
    );
    final byUid = <String, _ContactCandidate>{};
    for (final candidate in candidates) {
      final uid = candidate.card.uid;
      final current = byUid[uid];
      if (current == null || _isNewer(candidate.event, current.event)) {
        byUid[uid] = candidate;
      }
    }

    final contacts = <AddressBookContact>[];
    for (final entry in byUid.entries) {
      final uid = entry.key;
      final candidate = entry.value;
      final deletionTime = deletions[uid] ?? 0;
      final deleted = deletionTime > candidate.event.createdAt;
      contacts.add(
        AddressBookContact(
          uid: uid,
          vCard: candidate.card.text,
          index: candidate.card.index,
          eventId: candidate.event.id,
          eventCreatedAt: candidate.event.createdAt,
          pubKey: candidate.event.pubKey,
          status: deleted
              ? AddressBookContactStatus.deleted
              : AddressBookContactStatus.active,
        ),
      );
    }

    await _store.saveComputed(contacts: contacts, uidEvents: uidEvents);
    return contacts.length;
  }

  /// Returns the filters used by [fetchRecent].
  AddressBookFilters recentFilters() {
    return AddressBookFilters(
      contacts: contactFilter(limit: recentLimit),
      deletions: deletionFilter(limit: recentLimit),
    );
  }

  /// Builds the contact filter used by fetch/pull operations.
  Filter contactFilter({String? uid, int? limit, int? since, int? until}) {
    final pubkey = _requirePubkey();
    return Filter(
      kinds: [contactKind],
      authors: [pubkey],
      dTags: uid == null ? null : [uid],
      limit: uid != null ? (limit ?? 1) : limit,
      since: since,
      until: until,
    );
  }

  /// Builds the NIP-09 deletion filter used by fetch/pull operations.
  Filter deletionFilter({int? limit, int? since, int? until}) {
    final pubkey = _requirePubkey();
    return Filter(
      kinds: [deletionKind],
      authors: [pubkey],
      tags: {
        '#k': [contactKind.toString()],
      },
      limit: limit,
      since: since,
      until: until,
    );
  }

  /// Disposes the package-owned broadcast queue resources.
  Future<void> dispose() => broadcastQueue.dispose();

  Future<AddressBookSyncResult> _fetch({
    required Filter contactFilter,
    required Filter deletionFilter,
    required bool paginate,
    bool useFetchedRanges = false,
  }) async {
    final account = _requireAccount();
    final relays = await getReadRelays();
    final contactEvents = await _queryContacts(
      contactFilter,
      relays: relays,
      paginate: paginate,
      useFetchedRanges: useFetchedRanges,
    );
    final deletionEvents = await ndk.requests
        .query(
          filter: deletionFilter,
          explicitRelays: relays,
          desiredCoverage: relays.isEmpty ? null : 1,
          paginate: paginate,
        )
        .future;

    var decrypted = 0;
    var skipped = 0;
    for (final event in contactEvents) {
      if (event.pubKey != account.pubkey || event.kind != contactKind) {
        skipped++;
        continue;
      }
      final text = await account.signer.decryptNip44(
        ciphertext: event.content,
        senderPubKey: event.pubKey,
      );
      if (text == null) {
        skipped++;
        continue;
      }
      try {
        final canonical = VCardTools.parseExisting(text);
        if (canonical.uid != event.getDtag()) {
          skipped++;
          continue;
        }
        await _store.saveDecryptedEvent(event.id, canonical.text);
        decrypted++;
      } on NostrAddressBookException {
        skipped++;
      }
    }

    final computed = await rebuildComputedStores();
    return AddressBookSyncResult(
      fetchedEvents: contactEvents.length + deletionEvents.length,
      decryptedEvents: decrypted,
      skippedEvents: skipped,
      computedContacts: computed,
    );
  }

  Future<List<Nip01Event>> _queryContacts(
    Filter filter, {
    required List<String> relays,
    required bool paginate,
    required bool useFetchedRanges,
  }) async {
    if (!useFetchedRanges || filter.since == null && filter.until == null) {
      return ndk.requests
          .query(
            filter: filter,
            explicitRelays: relays,
            desiredCoverage: relays.isEmpty ? null : 1,
            paginate: paginate,
          )
          .future;
    }

    final relayUrls = relays;
    if (relayUrls.isEmpty) {
      return const [];
    }

    final since = filter.since ?? 0;
    final until = filter.until ?? Nip01Event.secondsSinceEpoch();
    // ignore: experimental_member_use
    final optimized = await ndk.fetchedRanges.getOptimizedFilters(
      filter: filter,
      since: since,
      until: until,
      relayUrls: relayUrls,
    );
    if (optimized.isEmpty) return const [];

    final responses = await Future.wait(
      optimized.entries.map((entry) async {
        final events = <Nip01Event>[];
        for (final optimizedFilter in entry.value) {
          final result = await ndk.requests
              .query(
                filter: optimizedFilter,
                explicitRelays: [entry.key],
                desiredCoverage: 1,
                paginate: paginate,
              )
              .future;
          events.addAll(result);
        }
        return events;
      }),
    );

    final byId = <String, Nip01Event>{};
    for (final events in responses) {
      for (final event in events) {
        byId[event.id] = event;
      }
    }
    return byId.values.toList(growable: false);
  }

  Future<Map<String, int>> _loadDeletionTimes({
    required Set<String> knownEventIds,
  }) async {
    final deletionEvents = await ndk.config.cache.loadEvents(
      kinds: [deletionKind],
    );
    final byUid = <String, int>{};

    for (final deletion in deletionEvents) {
      if (!_deletesAddressBookKind(deletion)) continue;
      final uidFromATags = deletion.getTags('a').map(_uidFromAddressTag);
      for (final uid in uidFromATags.whereType<String>()) {
        byUid[uid] = _max(byUid[uid], deletion.createdAt);
      }

      for (final eventId in deletion.getTags('e')) {
        if (!knownEventIds.contains(eventId)) continue;
        final deletedEvent = await ndk.config.cache.loadEvent(eventId);
        if (deletedEvent == null || deletedEvent.kind != contactKind) continue;
        final uid = deletedEvent.getDtag();
        if (uid == null || uid.isEmpty) continue;
        byUid[uid] = _max(byUid[uid], deletion.createdAt);
      }
    }

    return byUid;
  }

  bool _deletesAddressBookKind(Nip01Event deletion) {
    final kTags = deletion.getTags('k');
    if (kTags.isEmpty) {
      return deletion
          .getTags('a')
          .any((tag) => tag.startsWith('$contactKind:'));
    }
    return kTags.contains(contactKind.toString());
  }

  String? _uidFromAddressTag(String tag) {
    final parts = tag.split(':');
    if (parts.length < 3) return null;
    if (parts.first != contactKind.toString()) return null;
    return parts.sublist(2).join(':');
  }

  List<String> _relayFallback(Iterable<String> preferredRelays) {
    final relays = preferredRelays.toSet();
    if (relays.isEmpty) {
      relays.addAll(ndk.relays.connectedRelays.map((relay) => relay.url));
    }
    if (relays.isEmpty) {
      relays.addAll(ndk.config.bootstrapRelays);
    }
    return relays.where((relay) => relay.trim().isNotEmpty).toList();
  }

  Account _requireAccount() {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw const AddressBookAccountException(
        'A logged NDK account is required',
      );
    }
    return account;
  }

  Account _requireSigningAccount() {
    final account = _requireAccount();
    if (!account.signer.canSign()) {
      throw const AddressBookAccountException(
        'The logged NDK account cannot sign',
      );
    }
    return account;
  }

  String _requirePubkey() => _requireAccount().pubkey;

  bool _isNewer(Nip01Event incoming, Nip01Event current) {
    if (incoming.createdAt != current.createdAt) {
      return incoming.createdAt > current.createdAt;
    }
    return incoming.id.compareTo(current.id) < 0;
  }

  int _max(int? current, int next) {
    if (current == null || next > current) return next;
    return current;
  }
}

class _ContactCandidate {
  final Nip01Event event;
  final CanonicalVCard card;

  const _ContactCandidate({required this.event, required this.card});
}
