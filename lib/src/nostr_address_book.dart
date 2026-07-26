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

  /// Sembast database used for address-book raw decrypted data and computed
  /// data.
  final Database database;
  final AddressBookStore _store;

  /// Offline-first broadcast queue used to eventually publish contact and
  /// deletion events.
  ///
  /// The queue is caller-owned and may be shared with the rest of the app:
  /// the package only enqueues address-book events, attributed to the signing
  /// account, and never removes entries. Dropping an account's pending
  /// broadcasts at logout is the caller's call, through
  /// [OfflineBroadcast.clearLocalAccountData] or
  /// [OfflineBroadcast.clearAllLocalData]; so is [OfflineBroadcast.dispose].
  final OfflineBroadcast broadcastQueue;

  /// Creates an address book backed by [ndk] and [database].
  ///
  /// The constructor does not require a signer or relay list. Signing and
  /// NIP-44 self-encryption use the current account in `ndk.accounts`; relay
  /// selection is derived from NDK when events are queued for broadcast.
  ///
  /// [broadcastQueue] is caller-owned; the same instance can be shared with
  /// other packages broadcasting through the same database.
  NostrAddressBook({
    required this.ndk,
    required this.database,
    required this.broadcastQueue,
  }) : _store = AddressBookStore(database);

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
    final event = await account.signer.sign(
      Nip01Event(
        pubKey: account.pubkey,
        kind: contactKind,
        tags: [
          ['d', canonical.uid],
        ],
        content: encrypted,
        createdAt: now,
      ),
    );

    await ndk.config.cache.saveEvent(event);
    await _store.saveDecryptedEvent(
      event.id,
      pubkey: account.pubkey,
      vCardText: canonical.text,
    );
    await rebuildComputedStores();

    final relays = await getWriteRelays();
    if (relays.isNotEmpty) {
      await broadcastQueue.broadcast(
        event,
        relays: relays,
        pubkey: account.pubkey,
      );
    }

    final contact = await get(canonical.uid, pubkey: account.pubkey);
    if (contact == null) {
      throw const NostrAddressBookException('Contact was not materialized');
    }
    return contact;
  }

  /// Deletes the current account's contact with [uid] by queuing a NIP-09
  /// deletion event.
  ///
  /// The deletion event targets the latest known contact event. The computed
  /// contact is marked deleted locally after the deletion event is saved to the
  /// NDK cache; relay delivery remains the responsibility of [broadcastQueue].
  Future<void> delete(String uid, {String reason = 'delete'}) async {
    final account = _requireSigningAccount();
    final contact = await get(uid, pubkey: account.pubkey);
    if (contact == null || contact.deleted) return;

    final now = Nip01Event.secondsSinceEpoch();
    final event = await account.signer.sign(
      Nip01Event(
        pubKey: account.pubkey,
        kind: deletionKind,
        tags: [
          ['e', contact.eventId],
          ['a', '$contactKind:${account.pubkey}:$uid'],
          ['k', contactKind.toString()],
        ],
        content: reason,
        createdAt: now,
      ),
    );
    await ndk.config.cache.saveEvent(event);

    final relays = await getWriteRelays();
    if (relays.isNotEmpty) {
      await broadcastQueue.broadcast(
        event,
        relays: relays,
        pubkey: account.pubkey,
      );
    }
    await rebuildComputedStores();
  }

  /// Returns the local computed contact for [uid], or `null` if absent.
  ///
  /// [pubkey] selects the owning account; it defaults to the current account
  /// and is then required to be logged in.
  Future<AddressBookContact?> get(String uid, {String? pubkey}) {
    return _store.getContact(pubkey: pubkey ?? _requirePubkey(), uid: uid);
  }

  /// Lists local computed contacts.
  ///
  /// This reads only Sembast computed stores and does not require internet or
  /// a signer. Without [ContactQuery.pubkey] the result spans every account
  /// stored in the database.
  Future<List<AddressBookContact>> list({ContactQuery? query}) {
    return _store.list(query: query);
  }

  /// Watches local computed contacts.
  ///
  /// This is a Sembast watcher, not an NDK network subscription. Without
  /// [ContactQuery.pubkey] the stream spans every account stored in the
  /// database.
  Stream<List<AddressBookContact>> watchAll({ContactQuery? query}) {
    return _store.watchAll(query: query);
  }

  /// Watches a single local computed contact by [uid].
  ///
  /// This is a Sembast watcher, not an NDK network subscription. [pubkey]
  /// selects the owning account; it defaults to the current account and is
  /// then required to be logged in.
  Stream<AddressBookContact?> watch(String uid, {String? pubkey}) {
    return _store.watch(pubkey: pubkey ?? _requirePubkey(), uid: uid);
  }

  /// Drops and rebuilds all computed address-book stores.
  ///
  /// Rebuild uses only the NDK cache and the raw
  /// `address_book_decrypted_events` store, so it works without internet and
  /// without a signer. Raw decrypted entries whose encrypted NDK event is no
  /// longer present are ignored. Contacts are keyed per account, so identical
  /// uids owned by different accounts do not collide, and NIP-09 deletions
  /// only apply to contacts of their own author.
  ///
  /// Raw entries written before 0.2.0 carry no author; when their encrypted
  /// event is still cached they are rewritten with its pubkey so
  /// [clearLocalAccountData] can attribute them.
  Future<int> rebuildComputedStores() async {
    final decryptedEvents = await _store.loadAllDecryptedEvents();
    final candidates = <_ContactCandidate>[];
    final uidEvents = <({String pubkey, String uid}), List<String>>{};

    for (final entry in decryptedEvents.entries) {
      final event = await ndk.config.cache.loadEvent(entry.key);
      if (event == null || event.kind != contactKind) continue;
      final uid = event.getDtag();
      if (uid == null || uid.isEmpty) continue;
      try {
        final canonical = VCardTools.parseExisting(entry.value.vCardText);
        if (canonical.uid != uid) continue;
        if (entry.value.pubkey == null) {
          await _store.saveDecryptedEvent(
            event.id,
            pubkey: event.pubKey,
            vCardText: canonical.text,
          );
        }
        candidates.add(_ContactCandidate(event: event, card: canonical));
        uidEvents
            .putIfAbsent((pubkey: event.pubKey, uid: uid), () => [])
            .add(event.id);
      } on NostrAddressBookException {
        continue;
      }
    }

    final deletions = await _loadDeletionTimes(
      knownEventIds: candidates.map((candidate) => candidate.event.id).toSet(),
    );
    final byContact = <({String pubkey, String uid}), _ContactCandidate>{};
    for (final candidate in candidates) {
      final key = (pubkey: candidate.event.pubKey, uid: candidate.card.uid);
      final current = byContact[key];
      if (current == null || _isNewer(candidate.event, current.event)) {
        byContact[key] = candidate;
      }
    }

    final contacts = <AddressBookContact>[];
    for (final entry in byContact.entries) {
      final candidate = entry.value;
      final deletionTime = deletions[entry.key] ?? 0;
      final deleted = deletionTime > candidate.event.createdAt;
      contacts.add(
        AddressBookContact(
          uid: entry.key.uid,
          vCard: candidate.card.text,
          index: candidate.card.index,
          eventId: candidate.event.id,
          eventCreatedAt: candidate.event.createdAt,
          pubKey: entry.key.pubkey,
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
  ///
  /// [pubkey] overrides the author and defaults to the current account.
  Filter contactFilter({
    String? uid,
    int? limit,
    int? since,
    int? until,
    String? pubkey,
  }) {
    final author = pubkey ?? _requirePubkey();
    return Filter(
      kinds: [contactKind],
      authors: [author],
      dTags: uid == null ? null : [uid],
      limit: uid != null ? (limit ?? 1) : limit,
      since: since,
      until: until,
    );
  }

  /// Builds the NIP-09 deletion filter used by fetch/pull operations.
  ///
  /// [pubkey] overrides the author and defaults to the current account.
  Filter deletionFilter({int? limit, int? since, int? until, String? pubkey}) {
    final author = pubkey ?? _requirePubkey();
    return Filter(
      kinds: [deletionKind],
      authors: [author],
      tags: {
        '#k': [contactKind.toString()],
      },
      limit: limit,
      since: since,
      until: until,
    );
  }

  /// Removes the local address-book data of one account.
  ///
  /// This removes, for [pubkey] only:
  ///
  /// - raw decrypted vCard entries authored by that account;
  /// - kind [contactKind] events authored by that account in the NDK cache;
  /// - NIP-09 deletion events authored by that account targeting
  ///   [contactKind];
  /// - NDK fetched-range records of that account's contact and deletion
  ///   filters, so a later pull re-downloads everything.
  ///
  /// Computed stores are rebuilt afterwards, so contacts of other accounts
  /// sharing the same database survive. Pre-0.2.0 raw entries whose encrypted
  /// event is no longer cached cannot be attributed and are kept;
  /// [clearAllLocalData] removes those.
  ///
  /// The caller-owned [broadcastQueue] is not touched: also call
  /// [OfflineBroadcast.clearLocalAccountData] on it, otherwise the account's
  /// pending events are eventually published.
  ///
  /// No logged account is required, so this can run after logout. Relays are
  /// not contacted: events already published remain on relays and are fetched
  /// again on the next sync for that account.
  Future<void> clearLocalAccountData({required String pubkey}) async {
    final decryptedEvents = await _store.loadAllDecryptedEvents();
    final ownedEventIds = <String>[];
    for (final entry in decryptedEvents.entries) {
      if (entry.value.pubkey == pubkey) {
        ownedEventIds.add(entry.key);
      } else if (entry.value.pubkey == null) {
        final event = await ndk.config.cache.loadEvent(entry.key);
        if (event != null && event.pubKey == pubkey) {
          ownedEventIds.add(entry.key);
        }
      }
    }
    await _store.deleteDecryptedEvents(ownedEventIds);

    final deletionEvents = await ndk.config.cache.loadEvents(
      kinds: [deletionKind],
      pubKeys: [pubkey],
    );
    final deletionIds = deletionEvents
        .where(_deletesAddressBookKind)
        .map((event) => event.id)
        .toList(growable: false);
    if (deletionIds.isNotEmpty) {
      await ndk.config.cache.removeEvents(ids: deletionIds);
    }
    await ndk.config.cache.removeEvents(
      pubKeys: [pubkey],
      kinds: [contactKind],
    );

    await ndk.fetchedRanges.clearForFilter(contactFilter(pubkey: pubkey));
    await ndk.fetchedRanges.clearForFilter(deletionFilter(pubkey: pubkey));

    await rebuildComputedStores();
  }

  /// Removes all local address-book data, every account included.
  ///
  /// This empties the raw and computed Sembast stores and removes kind
  /// [contactKind] events and address-book NIP-09 deletions from the NDK
  /// cache. NDK fetched-range records are cleared globally, because past
  /// per-account filter hashes cannot be enumerated; other NDK consumers
  /// simply re-download once.
  ///
  /// The caller-owned [broadcastQueue] is not touched: also call
  /// [OfflineBroadcast.clearLocalAccountData] or
  /// [OfflineBroadcast.clearAllLocalData] on it, otherwise pending events are
  /// eventually published.
  ///
  /// No logged account is required. Relays are not contacted: events already
  /// published remain on relays.
  Future<void> clearAllLocalData() async {
    final deletionEvents = await ndk.config.cache.loadEvents(
      kinds: [deletionKind],
    );
    final deletionIds = deletionEvents
        .where(_deletesAddressBookKind)
        .map((event) => event.id)
        .toList(growable: false);
    if (deletionIds.isNotEmpty) {
      await ndk.config.cache.removeEvents(ids: deletionIds);
    }
    await ndk.config.cache.removeEvents(kinds: [contactKind]);

    await ndk.fetchedRanges.clearAll();

    await _store.clearAll();
  }

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
        await _store.saveDecryptedEvent(
          event.id,
          pubkey: event.pubKey,
          vCardText: canonical.text,
        );
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

  Future<Map<({String pubkey, String uid}), int>> _loadDeletionTimes({
    required Set<String> knownEventIds,
  }) async {
    final deletionEvents = await ndk.config.cache.loadEvents(
      kinds: [deletionKind],
    );
    final byContact = <({String pubkey, String uid}), int>{};

    for (final deletion in deletionEvents) {
      if (!_deletesAddressBookKind(deletion)) continue;
      for (final tag in deletion.getTags('a')) {
        final uid = _uidFromAddressTag(tag, author: deletion.pubKey);
        if (uid == null) continue;
        final key = (pubkey: deletion.pubKey, uid: uid);
        byContact[key] = _max(byContact[key], deletion.createdAt);
      }

      for (final eventId in deletion.getTags('e')) {
        if (!knownEventIds.contains(eventId)) continue;
        final deletedEvent = await ndk.config.cache.loadEvent(eventId);
        if (deletedEvent == null || deletedEvent.kind != contactKind) continue;
        // NIP-09: only the author may delete their own events.
        if (deletedEvent.pubKey != deletion.pubKey) continue;
        final uid = deletedEvent.getDtag();
        if (uid == null || uid.isEmpty) continue;
        final key = (pubkey: deletion.pubKey, uid: uid);
        byContact[key] = _max(byContact[key], deletion.createdAt);
      }
    }

    return byContact;
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

  String? _uidFromAddressTag(String tag, {required String author}) {
    final parts = tag.split(':');
    if (parts.length < 3) return null;
    if (parts.first != contactKind.toString()) return null;
    // NIP-09: only the author may delete their own addressable events.
    if (parts[1] != author) return null;
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
