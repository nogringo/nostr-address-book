import 'package:ndk/ndk.dart';
import 'package:nostr_address_book/nostr_address_book.dart';
import 'package:sembast/sembast_memory.dart';

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

  final book = NostrAddressBook(ndk: ndk, database: database);

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

  await book.fetchRecent();
  await book.pull(paginate: true);

  final contacts = await book.list();
  print('Local contacts: ${contacts.length}');

  ndk.accounts.logout();
  await book.rebuildComputedStores();
  print('Rebuilt computed stores without signer');

  await book.dispose();
  await ndk.destroy();
  await database.close();
}
