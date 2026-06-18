import 'package:ndk/ndk.dart';
import 'package:ndk/entities.dart' as ndk_entities;
import 'package:nostr_address_book/nostr_address_book.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:test/test.dart';

import 'support/mock_relay.dart';
import 'support/test_event_verifier.dart';

void main() {
  group('NostrAddressBook', () {
    late Database db;
    late Ndk ndk;
    late Bip340EventSigner signer;
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
      book = NostrAddressBook(ndk: ndk, database: db);
    });

    tearDown(() async {
      await book.dispose();
      await ndk.destroy();
      await db.close();
    });

    test(
      'upsert stores eventId to decrypted text and rebuilds without signer',
      () async {
        final input = _vcard(uid: 'urn:uuid:test-1', name: 'Alice Example');

        final contact = await book.upsertVCard(input);

        final raw = await StoreRef<String, String>(
          'address_book_decrypted_events',
        ).record(contact.eventId).get(db);
        expect(raw, input);

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

    test('read and write relays are resolved from NIP-65 markers', () async {
      await ndk.config.cache.saveUserRelayList(
        ndk_entities.UserRelayList(
          pubKey: signer.getPublicKey(),
          relays: {
            'wss://read.example': ndk_entities.ReadWriteMarker.readOnly,
            'wss://write.example': ndk_entities.ReadWriteMarker.writeOnly,
            'wss://both.example': ndk_entities.ReadWriteMarker.readWrite,
          },
          createdAt: 100,
          refreshedTimestamp: 100,
        ),
      );

      expect(
        await book.getReadRelays(),
        unorderedEquals(['wss://read.example', 'wss://both.example']),
      );
      expect(
        await book.getWriteRelays(),
        unorderedEquals(['wss://write.example', 'wss://both.example']),
      );
    });

    test('upsert and delete queue signed events for broadcast', () async {
      final relay = MockRelay(name: 'signed queue relay');
      await relay.startServer();
      try {
        const uid = 'urn:uuid:signed-queue';
        await ndk.config.cache.saveUserRelayList(
          ndk_entities.UserRelayList(
            pubKey: signer.getPublicKey(),
            relays: {relay.url: ndk_entities.ReadWriteMarker.writeOnly},
            createdAt: 100,
            refreshedTimestamp: 100,
          ),
        );

        final contact = await book.upsertVCard(
          _vcard(uid: uid, name: 'Signed Queue'),
        );
        final queued = await book.broadcastQueue.get(contact.eventId);

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
    late NostrAddressBook book;

    tearDown(() async {
      await book.dispose();
      await ndk.destroy();
      await relay.stopServer();
      await db.close();
    });

    test('fetchRecent uses limit 500 without paginate', () async {
      db = await databaseFactoryMemory.openDatabase('fetch_recent.db');
      signer = _newSigner();
      relay = MockRelay(name: 'fetch recent relay', maxEventsPerRequest: 1);
      await relay.startServer();
      ndk = _ndkForRelay(relay.url, signer);
      await _publishContactEvents(ndk, [
        await _encryptedContactEvent(
          signer: signer,
          uid: 'urn:uuid:recent-1',
          name: 'Recent One',
          createdAt: 100,
        ),
        await _encryptedContactEvent(
          signer: signer,
          uid: 'urn:uuid:recent-2',
          name: 'Recent Two',
          createdAt: 101,
        ),
      ]);
      await ndk.config.cache.clearAll();
      book = NostrAddressBook(ndk: ndk, database: db);

      final filters = book.recentFilters();
      final result = await book.fetchRecent();

      expect(filters.contacts.limit, NostrAddressBook.recentLimit);
      expect(filters.deletions.limit, NostrAddressBook.recentLimit);
      expect(result.decryptedEvents, 1);
      expect(await book.list(), hasLength(1));
    });

    test('pull paginates contact filters', () async {
      db = await databaseFactoryMemory.openDatabase('pull_paginate.db');
      signer = _newSigner();
      final events = <Nip01Event>[];
      for (var i = 0; i < 3; i++) {
        final event = await _encryptedContactEvent(
          signer: signer,
          uid: 'urn:uuid:page-$i',
          name: 'Page $i',
          createdAt: 100 + i,
        );
        events.add(event.event);
      }
      relay = MockRelay(name: 'pull paginate relay', maxEventsPerRequest: 1);
      await relay.startServer();
      ndk = _ndkForRelay(relay.url, signer);
      await _publishContactEvents(
        ndk,
        events.map((event) => _EncryptedContact(event: event, decrypted: '')),
      );
      await ndk.config.cache.clearAll();
      book = NostrAddressBook(ndk: ndk, database: db);

      final result = await book.pull(paginate: true);

      expect(result.decryptedEvents, 3);
      expect(await book.list(), hasLength(3));
    });
  });
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
