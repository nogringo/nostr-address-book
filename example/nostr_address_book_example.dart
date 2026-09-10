import 'package:broadcast_queue_shim_for_ndk/broadcast_queue_shim_for_ndk.dart';
import 'package:ndk/ndk.dart';
import 'package:nostr_address_book/nostr_address_book.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';

Future<void> main() async {
  final database = await databaseFactoryMemory.openDatabase('example.db');
  final ndk = Ndk(
    NdkConfig(
      cache: MemCacheManager(),
      eventVerifier: Bip340EventVerifier(),
      fetchedRangesEnabled: true,
    ),
  );

  const signerFactory = Bip340EventSignerFactory();
  final (privateKey, publicKey) = signerFactory.generateKeyPair();
  ndk.accounts.loginPrivateKey(pubkey: publicKey, privkey: privateKey);

  final broadcastQueue = OfflineBroadcast.withNdk(ndk, db: database);
  final syncEngine = SyncEngine(ndk, db: database)..start();
  final book = NostrAddressBook(
    ndk: ndk,
    database: database,
    broadcastQueue: broadcastQueue,
    syncEngine: syncEngine,
  );

  final contact = await book.upsertVCard('''
BEGIN:VCARD
VERSION:4.0
UID:urn:uuid:5cf497e2-0dfb-4f69-8b21-3ca6f5837d13
FN:Alice Example
N:Example;Alice;;;
EMAIL;TYPE=work;PREF=1:alice@example.com
TEL;TYPE=cell,voice:tel:+33123456789
IMPP:nostr:npub1example
END:VCARD
''');

  print('Saved ${contact.index.formattedName} (${contact.uid})');

  // Declared once: the engine keeps the cache in sync from there on, and each
  // landed page turns into contacts.
  await book.sync();
  await book.refresh();

  final contacts = await book.list();
  print('Local contacts: ${contacts.length}');

  ndk.accounts.logout();
  await book.rebuildComputedStores();
  print('Rebuilt computed stores without signer');

  // The queue is caller-owned: clear it alongside the address-book data.
  await broadcastQueue.clearLocalAccountData(pubkey: publicKey);
  await book.clearLocalAccountData(pubkey: publicKey);
  print('Cleared local data for $publicKey');

  await broadcastQueue.dispose();
  await syncEngine.dispose();
  await ndk.destroy();
  await database.close();
}
