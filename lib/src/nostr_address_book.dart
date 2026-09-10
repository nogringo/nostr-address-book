import 'package:broadcast_queue_shim_for_ndk/broadcast_queue_shim_for_ndk.dart';
import 'package:ndk/ndk.dart';
import 'package:sembast/sembast.dart' show Database;
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';

import 'address_book_sync.dart';
import 'address_book_store.dart';
import 'nostr_address_book_exception.dart';
import 'nostr_address_book_models.dart';
import 'vcard_tools.dart';

class NostrAddressBook {
  /// Nostr kind used for addressable encrypted vCard contact events.
  static const int contactKind = 38522;

  /// NIP-09 deletion event kind.
  static const int deletionKind = 5;

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

  /// Downward sync engine keeping the NDK cache in step with the relays.
  ///
  /// The engine is caller-owned and may be shared with the rest of the app:
  /// the package declares its own address-book requests through [sync] and
  /// only ever forgets those. Disposing the engine, or clearing everything it
  /// persisted, is the caller's call.
  final SyncEngine syncEngine;

  late final AddressBookSync _sync;

  /// Cached contact events that failed to decrypt or parse, so a landed page
  /// does not retry them. In memory only: a restart tries again.
  final Set<String> _unusableEvents = {};

  /// Creates an address book backed by [ndk] and [database].
  ///
  /// The constructor does not require a signer or relay list. Signing and
  /// NIP-44 self-encryption use the current account in `ndk.accounts`; relay
  /// selection is derived from NDK when events are queued for broadcast.
  ///
  /// [broadcastQueue] and [syncEngine] are caller-owned; the same instances
  /// can be shared with other packages working through the same database.
  NostrAddressBook({
    required this.ndk,
    required this.database,
    required this.broadcastQueue,
    required this.syncEngine,
  }) : _store = AddressBookStore(database) {
    _sync = AddressBookSync(
      engine: syncEngine,
      requestOf: (pubkey) => syncRequest(pubkey: pubkey),
      reconcileOf: (pubkey) async {
        final account = ndk.accounts.accounts[pubkey];
        if (account == null || !account.signer.canSign()) return null;
        return _reconcile(account);
      },
    );
  }

  /// Declares the address-book sync of one account and keeps it up to date.
  ///
  /// The engine fetches the missing contact and deletion events into the NDK
  /// cache, then revisits their recent end on its own, so the caller has no
  /// polling to write. Every page that lands is reconciled: newly cached
  /// events are decrypted and the computed stores are rebuilt.
  ///
  /// Calling this again is cheap and returns the same handle, unless
  /// [getReadRelays] no longer matches the relays the request was declared on:
  /// the previous handle is then released and a new one takes its place.
  ///
  /// The request authenticates as [pubkey], which defaults to the current
  /// account. That account must be in `ndk.accounts` and able to sign, or the
  /// engine reads nothing and reports a `SyncAuthUnavailable`.
  ///
  /// Reconciliation decrypts only for the currently logged account, so a
  /// request declared for another account materializes its contacts when that
  /// account is back and [reconcile] runs.
  Future<SyncHandle> sync({String? pubkey}) {
    return _sync.declare(pubkey ?? _requirePubkey());
  }

  /// Fetches now, however fresh the coverage is, then reconciles.
  ///
  /// This is the pull to refresh gesture. It declares the sync of the current
  /// account if [sync] has not run yet, and returns what every reconciliation
  /// pass made of the events that landed while it ran, background passes on
  /// the pages of this very refresh included.
  Future<AddressBookSyncResult> refresh() {
    return _sync.refresh(_requireSigningAccount().pubkey);
  }

  /// Turns the cached contact events of the current account into contacts.
  ///
  /// Every kind [contactKind] event of that account in the NDK cache that has
  /// no decrypted entry yet is decrypted, stored, and the computed stores are
  /// rebuilt. This is what [sync] runs on each landed page; call it directly
  /// after events reached the cache through another path.
  Future<AddressBookSyncResult> reconcile() {
    return _sync.reconcile(_requireSigningAccount().pubkey);
  }

  /// Drops this package's interest in the sync of one account.
  ///
  /// What was synced stays in the cache and the coverage stays recorded, so a
  /// later [sync] resumes rather than walking everything back. [pubkey]
  /// defaults to the current account.
  void stopSync({String? pubkey}) => _sync.release(pubkey ?? _requirePubkey());

  /// Drops this package's interest in every account's sync.
  ///
  /// No logged account is required, so this can run at logout or shutdown.
  void stopAllSync() => _sync.releaseAll();

  /// Builds the sync request of one account, as [sync] declares it.
  ///
  /// Exposed so the caller can watch its status through
  /// `syncEngine.watchStatus`, or hand it to `syncEngine.forget`. [pubkey]
  /// defaults to the current account.
  Future<SyncRequest> syncRequest({String? pubkey}) async {
    final target = pubkey ?? _requirePubkey();
    return SyncRequest(
      filters: [
        contactFilter(pubkey: target),
        deletionFilter(pubkey: target),
      ],
      relays: await getReadRelays(pubkey: target),
      authPubkey: target,
    );
  }

  /// Returns the relay URLs used for reading address-book events.
  ///
  /// The list comes from the NIP-65 read relays of [pubkey], which defaults to
  /// the current account, through `ndk.userRelayLists`. If no read relay is
  /// available, the method falls back explicitly to currently connected
  /// relays, then NDK bootstrap relays.
  Future<List<String>> getReadRelays({
    String? pubkey,
    bool forceRefresh = false,
  }) async {
    final userRelayList = await ndk.userRelayLists.getSingleUserRelayList(
      pubkey ?? _requirePubkey(),
      forceRefresh: forceRefresh,
    );
    return _relayFallback(userRelayList?.readUrls ?? const []);
  }

  /// Returns the relay URLs used for publishing address-book events.
  ///
  /// The list comes from the NIP-65 write relays of [pubkey], which defaults
  /// to the current account, through `ndk.userRelayLists`. If no write relay
  /// is available, the method falls back explicitly to currently connected
  /// relays, then NDK bootstrap relays.
  Future<List<String>> getWriteRelays({
    String? pubkey,
    bool forceRefresh = false,
  }) async {
    final userRelayList = await ndk.userRelayLists.getSingleUserRelayList(
      pubkey ?? _requirePubkey(),
      forceRefresh: forceRefresh,
    );
    return _relayFallback(userRelayList?.writeUrls ?? const []);
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

  /// Builds the contact filter of a sync request.
  ///
  /// [pubkey] overrides the author and defaults to the current account.
  /// [since] and [until] bound the window; without them the engine walks back
  /// to the oldest contact event the relays hold. A `limit` would be ignored
  /// by the engine, so the filter carries none.
  Filter contactFilter({String? pubkey, int? since, int? until}) {
    return Filter(
      kinds: [contactKind],
      authors: [pubkey ?? _requirePubkey()],
      since: since,
      until: until,
    );
  }

  /// Builds the NIP-09 deletion filter of a sync request.
  ///
  /// [pubkey] overrides the author and defaults to the current account.
  Filter deletionFilter({String? pubkey, int? since, int? until}) {
    return Filter(
      kinds: [deletionKind],
      authors: [pubkey ?? _requirePubkey()],
      tags: {
        '#k': [contactKind.toString()],
      },
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
  /// - the sync coverage of that account's requests, on every relay they were
  ///   was synced from, so a later [sync] walks them back from scratch.
  ///
  /// The account's sync is released; other accounts keep syncing.
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

    await _forgetSync(pubkey);
    _unusableEvents.clear();

    await rebuildComputedStores();
  }

  /// Removes all local address-book data, every account included.
  ///
  /// This empties the raw and computed Sembast stores, removes kind
  /// [contactKind] events and address-book NIP-09 deletions from the NDK
  /// cache, and forgets the sync coverage of every address-book request ever
  /// declared. Requests of other packages sharing the engine are untouched.
  ///
  /// The caller-owned [broadcastQueue] is not touched: also call
  /// [OfflineBroadcast.clearLocalAccountData] or
  /// [OfflineBroadcast.clearAllLocalData] on it, otherwise pending events are
  /// eventually published.
  ///
  /// No logged account is required. Relays are not contacted: events already
  /// published remain on relays.
  Future<void> clearAllLocalData() async {
    final contactEvents = await ndk.config.cache.loadEvents(
      kinds: [contactKind],
    );
    final decryptedEvents = await _store.loadAllDecryptedEvents();
    final accounts = {
      ..._sync.declaredAccounts,
      ...contactEvents.map((event) => event.pubKey),
      ...decryptedEvents.values.map((entry) => entry.pubkey).nonNulls,
    };

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

    for (final pubkey in accounts) {
      await _forgetSync(pubkey);
    }
    stopAllSync();
    _unusableEvents.clear();

    await _store.clearAll();
  }

  Future<AddressBookSyncResult> _reconcile(Account account) async {
    final cached = await ndk.config.cache.loadEvents(
      kinds: [contactKind],
      pubKeys: [account.pubkey],
    );
    final known = await _store.loadAllDecryptedEvents();

    var decrypted = 0;
    var skipped = 0;
    for (final event in cached) {
      if (known.containsKey(event.id) || _unusableEvents.contains(event.id)) {
        continue;
      }
      final text = await account.signer.decryptNip44(
        ciphertext: event.content,
        senderPubKey: event.pubKey,
      );
      if (text == null) {
        _unusableEvents.add(event.id);
        skipped++;
        continue;
      }
      try {
        final canonical = VCardTools.parseExisting(text);
        if (canonical.uid != event.getDtag()) {
          _unusableEvents.add(event.id);
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
        _unusableEvents.add(event.id);
        skipped++;
      }
    }

    final computed = await rebuildComputedStores();
    return AddressBookSyncResult(
      decryptedEvents: decrypted,
      skippedEvents: skipped,
      computedContacts: computed,
    );
  }

  /// Forgets the coverage of [pubkey]'s filters, on every relay they were
  /// synced from, and releases its request.
  Future<void> _forgetSync(String pubkey) {
    return _sync.forget(pubkey, [
      contactFilter(pubkey: pubkey),
      deletionFilter(pubkey: pubkey),
    ]);
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
