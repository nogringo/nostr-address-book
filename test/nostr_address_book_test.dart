import 'package:broadcast_queue_shim_for_ndk/broadcast_queue_shim_for_ndk.dart';
import 'package:ndk/ndk.dart';
import 'package:ndk/entities.dart' as ndk_entities;
import 'package:nostr_address_book/nostr_address_book.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';
import 'package:test/test.dart';

import 'support/mock_relay.dart';
import 'support/test_event_verifier.dart';

void main() {
  group('NostrAddressBook', () {
    late Database db;
    late Ndk ndk;
    late Bip340EventSigner signer;
    late OfflineBroadcast queue;
    late SyncEngine engine;
    late NostrAddressBook book;

    setUp(() async {
      db = await databaseFactoryMemory.openDatabase('address_book_test.db');
      signer = _newSigner();
      ndk = Ndk(
        NdkConfig(
          eventVerifier: TestEventVerifier(),
          cache: MemCacheManager(),
          bootstrapRelays: const [],
          fetchedRangesEnabled: true,
          logLevel: LogLevel.off,
        ),
      );
      ndk.accounts.loginExternalSigner(signer: signer);
      queue = OfflineBroadcast.withNdk(
        ndk,
        db: db,
        perAttemptTimeout: const Duration(seconds: 1),
      );
      engine = SyncEngine(ndk, db: db)..start();
      book = NostrAddressBook(
        ndk: ndk,
        database: db,
        broadcastQueue: queue,
        syncEngine: engine,
      );
    });

    tearDown(() async {
      await queue.dispose();
      await engine.dispose();
      await ndk.destroy();
      await db.close();
    });

    test(
      'upsert stores eventId to decrypted text and rebuilds without signer',
      () async {
        final input = _vcard(uid: 'urn:uuid:test-1', name: 'Alice Example');

        final contact = await book.upsertVCard(input);

        final raw = await stringMapStoreFactory
            .store('address_book_decrypted_events')
            .record(contact.eventId)
            .get(db);
        expect(raw?['vcard'], input);
        expect(raw?['pubkey'], signer.getPublicKey());

        ndk.accounts.logout();
        final rebuiltCount = await book.rebuildComputedStores();
        final contacts = await book.list();

        expect(rebuiltCount, 1);
        expect(contacts, hasLength(1));
        expect(contacts.single.uid, 'urn:uuid:test-1');
        expect(contacts.single.index.formattedName, 'Alice Example');
        expect(contacts.single.deleted, isFalse);
      },
    );

    test('newest contact wins when rebuilding computed stores', () async {
      final uid = 'urn:uuid:test-newest';
      final older = await _encryptedContactEvent(
        signer: signer,
        uid: uid,
        name: 'Old Name',
        createdAt: 100,
      );
      final newer = await _encryptedContactEvent(
        signer: signer,
        uid: uid,
        name: 'New Name',
        createdAt: 200,
      );

      await ndk.config.cache.saveEvents([older.event, newer.event]);
      await StoreRef<String, String>(
        'address_book_decrypted_events',
      ).record(older.event.id).put(db, older.decrypted);
      await StoreRef<String, String>(
        'address_book_decrypted_events',
      ).record(newer.event.id).put(db, newer.decrypted);

      await book.rebuildComputedStores();
      final contact = await book.get(uid);

      expect(contact, isNotNull);
      expect(contact!.index.formattedName, 'New Name');
      expect(contact.eventId, newer.event.id);
    });

    test('deletion marks contact deleted and newer card restores it', () async {
      final uid = 'urn:uuid:test-delete';
      final card = await _encryptedContactEvent(
        signer: signer,
        uid: uid,
        name: 'Deleted Name',
        createdAt: 100,
      );
      final deletion = Nip01Event(
        pubKey: signer.getPublicKey(),
        kind: NostrAddressBook.deletionKind,
        tags: [
          ['e', card.event.id],
          [
            'a',
            '${NostrAddressBook.contactKind}:${signer.getPublicKey()}:$uid',
          ],
          ['k', NostrAddressBook.contactKind.toString()],
        ],
        content: 'delete',
        createdAt: 150,
      );
      final restored = await _encryptedContactEvent(
        signer: signer,
        uid: uid,
        name: 'Restored Name',
        createdAt: 200,
      );

      await ndk.config.cache.saveEvents([card.event, deletion]);
      await StoreRef<String, String>(
        'address_book_decrypted_events',
      ).record(card.event.id).put(db, card.decrypted);

      await book.rebuildComputedStores();
      expect((await book.get(uid))!.deleted, isTrue);

      await ndk.config.cache.saveEvent(restored.event);
      await StoreRef<String, String>(
        'address_book_decrypted_events',
      ).record(restored.event.id).put(db, restored.decrypted);

      await book.rebuildComputedStores();
      final contact = await book.get(uid);
      expect(contact!.deleted, isFalse);
      expect(contact.index.formattedName, 'Restored Name');
    });

    test('delete queues an empty version addressed by a tag only', () async {
      final relay = MockRelay(name: 'tombstone relay');
      await relay.startServer();
      try {
        const uid = 'urn:uuid:tombstone';
        await _seedRelayList(ndk, signer.getPublicKey(), {
          relay.url: ndk_entities.ReadWriteMarker.writeOnly,
        });
        await book.upsertVCard(_vcard(uid: uid, name: 'To Delete'));

        await book.delete(uid);

        final queued = (await queue.listAll())
            .map((entry) => entry.event)
            .toList();
        final tombstone = queued
            .where(
              (event) =>
                  event.kind == NostrAddressBook.contactKind &&
                  event.content.isEmpty,
            )
            .single;
        final deletion = queued
            .where((event) => event.kind == NostrAddressBook.deletionKind)
            .single;

        expect(tombstone.getDtag(), uid);
        expect(tombstone.sig, isNotEmpty);
        expect(tombstone.createdAt, deletion.createdAt);
        expect(deletion.getTags('e'), isEmpty);
        expect(deletion.getTags('a'), [
          '${NostrAddressBook.contactKind}:${signer.getPublicKey()}:$uid',
        ]);
        expect(deletion.getTags('k'), [
          NostrAddressBook.contactKind.toString(),
        ]);
        expect((await book.get(uid))!.deleted, isTrue);
      } finally {
        await relay.stopServer();
      }
    });

    test('an e tag deletion only removes the version it names', () async {
      const uid = 'urn:uuid:by-id';
      final stale = await _encryptedContactEvent(
        signer: signer,
        uid: uid,
        name: 'Stale Version',
        createdAt: 100,
      );
      final current = await _encryptedContactEvent(
        signer: signer,
        uid: uid,
        name: 'Current Version',
        createdAt: 200,
      );
      final deletion = Nip01Event(
        pubKey: signer.getPublicKey(),
        kind: NostrAddressBook.deletionKind,
        tags: [
          ['e', stale.event.id],
          ['k', NostrAddressBook.contactKind.toString()],
        ],
        content: 'delete',
        createdAt: 300,
      );

      await ndk.config.cache.saveEvents([stale.event, current.event, deletion]);
      await _seedRaw(db, stale, signer.getPublicKey());
      await _seedRaw(db, current, signer.getPublicKey());

      await book.rebuildComputedStores();

      final contact = await book.get(uid);
      expect(contact!.deleted, isFalse);
      expect(contact.index.formattedName, 'Current Version');
    });

    test('a deletion sharing the contact second still applies', () async {
      const uid = 'urn:uuid:same-second';
      final card = await _encryptedContactEvent(
        signer: signer,
        uid: uid,
        name: 'Same Second',
        createdAt: 100,
      );
      final deletion = Nip01Event(
        pubKey: signer.getPublicKey(),
        kind: NostrAddressBook.deletionKind,
        tags: [
          [
            'a',
            '${NostrAddressBook.contactKind}:${signer.getPublicKey()}:$uid',
          ],
          ['k', NostrAddressBook.contactKind.toString()],
        ],
        content: 'delete',
        createdAt: 100,
      );

      await ndk.config.cache.saveEvents([card.event, deletion]);
      await _seedRaw(db, card, signer.getPublicKey());

      await book.rebuildComputedStores();

      expect((await book.get(uid))!.deleted, isTrue);
    });

    test('reconcile ignores an empty version without marking it '
        'unusable', () async {
      const uid = 'urn:uuid:remote-tombstone';
      final tombstone = Nip01Event(
        pubKey: signer.getPublicKey(),
        kind: NostrAddressBook.contactKind,
        tags: [
          ['d', uid],
        ],
        content: '',
        createdAt: 200,
      );
      await ndk.config.cache.saveEvent(tombstone);

      final result = await book.reconcile();

      expect(result.decryptedEvents, 0);
      expect(result.skippedEvents, 0);
      expect(await book.get(uid), isNull);
    });

    test('reconcile decrypts cached events that landed on their own', () async {
      const uid = 'urn:uuid:reconciled';
      final card = await _encryptedContactEvent(
        signer: signer,
        uid: uid,
        name: 'Landed Alone',
        createdAt: 100,
      );
      await ndk.config.cache.saveEvent(card.event);

      final result = await book.reconcile();

      expect(result.decryptedEvents, 1);
      expect((await book.get(uid))!.index.formattedName, 'Landed Alone');

      // A second pass has nothing left to decrypt.
      expect((await book.reconcile()).decryptedEvents, 0);
    });

    test('read and write relays are resolved from NIP-65 markers', () async {
      await _seedRelayList(ndk, signer.getPublicKey(), {
        'wss://read.example': ndk_entities.ReadWriteMarker.readOnly,
        'wss://write.example': ndk_entities.ReadWriteMarker.writeOnly,
        'wss://both.example': ndk_entities.ReadWriteMarker.readWrite,
      });

      expect(
        await book.getReadRelays(),
        unorderedEquals(['wss://read.example', 'wss://both.example']),
      );
      expect(
        await book.getWriteRelays(),
        unorderedEquals(['wss://write.example', 'wss://both.example']),
      );
    });

    test('same uid across accounts stays separate, deletions stay per '
        'account', () async {
      const uid = 'urn:uuid:shared';
      final signerB = _newSigner();
      final cardA = await _encryptedContactEvent(
        signer: signer,
        uid: uid,
        name: 'From A',
        createdAt: 100,
      );
      final cardB = await _encryptedContactEvent(
        signer: signerB,
        uid: uid,
        name: 'From B',
        createdAt: 200,
      );
      final deletionByA = Nip01Event(
        pubKey: signer.getPublicKey(),
        kind: NostrAddressBook.deletionKind,
        tags: [
          [
            'a',
            '${NostrAddressBook.contactKind}:${signer.getPublicKey()}:$uid',
          ],
          ['k', NostrAddressBook.contactKind.toString()],
        ],
        content: 'delete',
        createdAt: 150,
      );

      await ndk.config.cache.saveEvents([
        cardA.event,
        cardB.event,
        deletionByA,
      ]);
      await _seedRaw(db, cardA, signer.getPublicKey());
      await _seedRaw(db, cardB, signerB.getPublicKey());

      await book.rebuildComputedStores();

      final all = await book.list(
        query: const ContactQuery(includeDeleted: true),
      );
      expect(all, hasLength(2));

      final contactA = await book.get(uid, pubkey: signer.getPublicKey());
      final contactB = await book.get(uid, pubkey: signerB.getPublicKey());
      expect(contactA!.deleted, isTrue);
      expect(contactB!.deleted, isFalse);
      expect(contactB.index.formattedName, 'From B');

      final onlyB = await book.list(
        query: ContactQuery(pubkey: signerB.getPublicKey()),
      );
      expect(onlyB.single.pubKey, signerB.getPublicKey());
    });

    test('clearLocalAccountData removes one account only', () async {
      final relay = MockRelay(name: 'clear account relay');
      await relay.startServer();
      try {
        final signerB = _newSigner();
        for (final pubkey in [signer.getPublicKey(), signerB.getPublicKey()]) {
          await _seedRelayList(ndk, pubkey, {
            relay.url: ndk_entities.ReadWriteMarker.readWrite,
          });
        }

        await book.upsertVCard(
          _vcard(uid: 'urn:uuid:owned-a', name: 'Owned A'),
        );
        await book.delete('urn:uuid:owned-a');
        ndk.accounts.logout();
        ndk.accounts.loginExternalSigner(signer: signerB);
        final contactB = await book.upsertVCard(
          _vcard(uid: 'urn:uuid:owned-b', name: 'Owned B'),
        );

        await book.clearLocalAccountData(pubkey: signer.getPublicKey());

        final remaining = await book.list(
          query: const ContactQuery(includeDeleted: true),
        );
        expect(remaining.single.uid, 'urn:uuid:owned-b');
        expect(
          await book.get('urn:uuid:owned-a', pubkey: signer.getPublicKey()),
          isNull,
        );

        expect(
          await ndk.config.cache.loadEvents(
            kinds: [NostrAddressBook.contactKind],
            pubKeys: [signer.getPublicKey()],
          ),
          isEmpty,
        );
        expect(
          await ndk.config.cache.loadEvents(
            kinds: [NostrAddressBook.deletionKind],
            pubKeys: [signer.getPublicKey()],
          ),
          isEmpty,
        );
        expect(
          await ndk.config.cache.loadEvents(
            kinds: [NostrAddressBook.contactKind],
            pubKeys: [signerB.getPublicKey()],
          ),
          hasLength(1),
        );

        // The caller-owned queue is untouched by the package clear, and every
        // entry of A (contact + tombstone + deletion) is attributed to it.
        final entriesOfA = (await queue.listAll()).where(
          (entry) => entry.pubkey == signer.getPublicKey(),
        );
        expect(entriesOfA, hasLength(3));

        await queue.clearLocalAccountData(pubkey: signer.getPublicKey());

        expect(
          (await queue.listAll()).where(
            (entry) => entry.pubkey == signer.getPublicKey(),
          ),
          isEmpty,
        );
        expect(
          await queue.get(contactB.eventId, pubkey: signerB.getPublicKey()),
          isNotNull,
        );
      } finally {
        await relay.stopServer();
      }
    });

    test('clearAllLocalData wipes stores and cache, not the queue', () async {
      final relay = MockRelay(name: 'clear all relay');
      await relay.startServer();
      try {
        await _seedRelayList(ndk, signer.getPublicKey(), {
          relay.url: ndk_entities.ReadWriteMarker.readWrite,
        });
        await book.upsertVCard(_vcard(uid: 'urn:uuid:wipe-me', name: 'Wipe'));
        await book.delete('urn:uuid:wipe-me');

        await book.clearAllLocalData();

        expect(
          await book.list(query: const ContactQuery(includeDeleted: true)),
          isEmpty,
        );
        expect(await book.rebuildComputedStores(), 0);

        // The caller-owned queue is untouched by the package clear.
        expect(await queue.listAll(), isNotEmpty);
        await queue.clearAllLocalData();
        expect(await queue.listAll(), isEmpty);
        expect(
          await ndk.config.cache.loadEvents(
            kinds: [NostrAddressBook.contactKind],
          ),
          isEmpty,
        );
        expect(
          await stringMapStoreFactory
              .store('address_book_decrypted_events')
              .find(db),
          isEmpty,
        );
      } finally {
        await relay.stopServer();
      }
    });

    test(
      'pre-0.2.0 raw entries are attributed on rebuild and cleared',
      () async {
        final card = await _encryptedContactEvent(
          signer: signer,
          uid: 'urn:uuid:legacy',
          name: 'Legacy',
          createdAt: 100,
        );
        await ndk.config.cache.saveEvent(card.event);
        await StoreRef<String, String>(
          'address_book_decrypted_events',
        ).record(card.event.id).put(db, card.decrypted);

        await book.rebuildComputedStores();

        final healed = await stringMapStoreFactory
            .store('address_book_decrypted_events')
            .record(card.event.id)
            .get(db);
        expect(healed?['pubkey'], signer.getPublicKey());

        await book.clearLocalAccountData(pubkey: signer.getPublicKey());

        expect(
          await book.get('urn:uuid:legacy', pubkey: signer.getPublicKey()),
          isNull,
        );
        expect(
          await stringMapStoreFactory
              .store('address_book_decrypted_events')
              .record(card.event.id)
              .get(db),
          isNull,
        );
      },
    );

    test('upsert and delete queue signed events for broadcast', () async {
      final relay = MockRelay(name: 'signed queue relay');
      await relay.startServer();
      try {
        const uid = 'urn:uuid:signed-queue';
        await _seedRelayList(ndk, signer.getPublicKey(), {
          relay.url: ndk_entities.ReadWriteMarker.writeOnly,
        });

        final contact = await book.upsertVCard(
          _vcard(uid: uid, name: 'Signed Queue'),
        );
        final queued = await book.broadcastQueue.get(
          contact.eventId,
          pubkey: signer.getPublicKey(),
        );

        expect(queued, isNotNull);
        expect(queued!.event.sig, isNotNull);
        expect(queued.event.sig, isNotEmpty);

        await book.delete(uid);
        final queuedEvents = await book.broadcastQueue.listAll();
        final queuedDeletion = queuedEvents.singleWhere(
          (entry) => entry.event.kind == NostrAddressBook.deletionKind,
        );

        expect(queuedDeletion.event.sig, isNotNull);
        expect(queuedDeletion.event.sig, isNotEmpty);
      } finally {
        await relay.stopServer();
      }
    });
  });

  group('network fetch', () {
    late Database db;
    late Bip340EventSigner signer;
    late MockRelay relay;
    late Ndk ndk;
    late OfflineBroadcast queue;
    late SyncEngine engine;
    late NostrAddressBook book;

    tearDown(() async {
      await queue.dispose();
      await engine.dispose();
      await ndk.destroy();
      await relay.stopServer();
      await db.close();
    });

    test('refresh syncs contacts and materializes them', () async {
      db = await databaseFactoryMemory.openDatabase('refresh_sync.db');
      signer = _newSigner();
      final events = <Nip01Event>[];
      for (var i = 0; i < 3; i++) {
        final contact = await _encryptedContactEvent(
          signer: signer,
          uid: 'urn:uuid:sync-$i',
          name: 'Sync $i',
          createdAt: Nip01Event.secondsSinceEpoch() - i,
        );
        events.add(contact.event);
      }
      relay = MockRelay(name: 'refresh sync relay');
      await relay.startServer();
      ndk = _ndkForRelay(relay.url, signer);
      await _publishContactEvents(
        ndk,
        events.map((event) => _EncryptedContact(event: event, decrypted: '')),
      );
      await ndk.config.cache.clearAll();
      queue = OfflineBroadcast.withNdk(
        ndk,
        db: db,
        perAttemptTimeout: const Duration(seconds: 1),
      );
      engine = SyncEngine(ndk, db: db)..start();
      book = NostrAddressBook(
        ndk: ndk,
        database: db,
        broadcastQueue: queue,
        syncEngine: engine,
      );

      final result = await book.refresh();

      expect(result.decryptedEvents, 3);
      expect(await book.list(), hasLength(3));
    });

    test('sync keeps one handle, clearing forgets its coverage', () async {
      db = await databaseFactoryMemory.openDatabase('sync_handle.db');
      signer = _newSigner();
      relay = MockRelay(name: 'sync handle relay');
      await relay.startServer();
      ndk = _ndkForRelay(relay.url, signer);
      queue = OfflineBroadcast.withNdk(
        ndk,
        db: db,
        perAttemptTimeout: const Duration(seconds: 1),
      );
      engine = SyncEngine(ndk, db: db)..start();
      book = NostrAddressBook(
        ndk: ndk,
        database: db,
        broadcastQueue: queue,
        syncEngine: engine,
      );

      final handle = await book.sync();
      expect(await book.sync(), handle);
      // Racing declarations must not register the request twice.
      expect((await Future.wait([book.sync(), book.sync()])).toSet(), {handle});

      await book.refresh();
      final filter = book.contactFilter();
      expect(
        await engine.coverageOfFilter(
          filter,
          authPubkey: signer.getPublicKey(),
        ),
        isNotEmpty,
      );

      await book.clearLocalAccountData(pubkey: signer.getPublicKey());

      expect(
        await engine.coverageOfFilter(
          filter,
          authPubkey: signer.getPublicKey(),
        ),
        isEmpty,
      );
    });
  });
}

/// NDK derives the cached user relay list from kind 10002 events, so a bare
/// `saveUserRelayList` is dropped as soon as any other event of that author is
/// cached (ndk >= 0.8.4-dev.11).
Future<void> _seedRelayList(
  Ndk ndk,
  String pubkey,
  Map<String, ndk_entities.ReadWriteMarker> relays,
) {
  return ndk.config.cache.saveEvent(
    ndk_entities.Nip65(
      pubKey: pubkey,
      relays: relays,
      createdAt: 100,
    ).toEvent(),
  );
}

Future<void> _seedRaw(Database db, _EncryptedContact contact, String pubkey) {
  return stringMapStoreFactory
      .store('address_book_decrypted_events')
      .record(contact.event.id)
      .put(db, {'pubkey': pubkey, 'vcard': contact.decrypted});
}

Bip340EventSigner _newSigner() {
  const factory = Bip340EventSignerFactory();
  final keys = factory.generateKeyPair();
  return Bip340EventSigner(privateKey: keys.$1, publicKey: keys.$2);
}

Ndk _ndkForRelay(String relayUrl, Bip340EventSigner signer) {
  final ndk = Ndk(
    NdkConfig(
      eventVerifier: TestEventVerifier(),
      cache: MemCacheManager(),
      bootstrapRelays: [relayUrl],
      fetchedRangesEnabled: true,
      defaultQueryTimeout: const Duration(seconds: 2),
      logLevel: LogLevel.off,
    ),
  );
  ndk.accounts.loginExternalSigner(signer: signer);
  return ndk;
}

Future<void> _publishContactEvents(
  Ndk ndk,
  Iterable<_EncryptedContact> contacts,
) async {
  await ndk.relays.seedRelaysConnected;
  for (final contact in contacts) {
    final response = ndk.broadcast.broadcast(
      nostrEvent: contact.event,
      specificRelays: ndk.config.bootstrapRelays,
    );
    await response.broadcastDoneFuture;
  }
}

String _vcard({required String uid, required String name}) {
  return [
    'BEGIN:VCARD',
    'VERSION:4.0',
    'UID:$uid',
    'FN:$name',
    'N:;$name;;;',
    'EMAIL:$name@example.com',
    'IMPP:nostr:npub1example',
    'END:VCARD',
  ].join('\r\n');
}

Future<_EncryptedContact> _encryptedContactEvent({
  required Bip340EventSigner signer,
  required String uid,
  required String name,
  required int createdAt,
}) async {
  final decrypted = _vcard(uid: uid, name: name);
  final encrypted = await signer.encryptNip44(
    plaintext: decrypted,
    recipientPubKey: signer.getPublicKey(),
  );
  final event = Nip01Event(
    pubKey: signer.getPublicKey(),
    kind: NostrAddressBook.contactKind,
    tags: [
      ['d', uid],
    ],
    content: encrypted!,
    createdAt: createdAt,
  );
  return _EncryptedContact(event: event, decrypted: decrypted);
}

class _EncryptedContact {
  final Nip01Event event;
  final String decrypted;

  const _EncryptedContact({required this.event, required this.decrypted});
}
