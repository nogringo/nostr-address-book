import 'package:sembast/sembast.dart';

import 'nostr_address_book_models.dart';

class DecryptedEventEntry {
  /// Author of the encrypted event; `null` for entries written before 0.2.0.
  final String? pubkey;
  final String vCardText;

  const DecryptedEventEntry({required this.pubkey, required this.vCardText});
}

class AddressBookStore {
  static const decryptedEventsName = 'address_book_decrypted_events';
  static const contactsName = 'address_book_contacts';
  static const contactIndexName = 'address_book_contact_index';
  static const uidEventsName = 'address_book_uid_events';

  final Database _database;
  final StoreRef<String, Object> _decryptedEvents;
  final StoreRef<String, Map<String, Object?>> _contacts;
  final StoreRef<String, Map<String, Object?>> _contactIndex;
  final StoreRef<String, Map<String, Object?>> _uidEvents;

  AddressBookStore(Database database)
    : _database = database,
      _decryptedEvents = StoreRef<String, Object>(decryptedEventsName),
      _contacts = stringMapStoreFactory.store(contactsName),
      _contactIndex = stringMapStoreFactory.store(contactIndexName),
      _uidEvents = stringMapStoreFactory.store(uidEventsName);

  /// Computed-store record key; the 64-char hex pubkey prefix keeps uids of
  /// different accounts from colliding.
  static String contactKey({required String pubkey, required String uid}) =>
      '$pubkey:$uid';

  Future<void> saveDecryptedEvent(
    String eventId, {
    required String pubkey,
    required String vCardText,
  }) {
    return _decryptedEvents.record(eventId).put(_database, {
      'pubkey': pubkey,
      'vcard': vCardText,
    });
  }

  Future<Map<String, DecryptedEventEntry>> loadAllDecryptedEvents() async {
    final records = await _decryptedEvents.find(_database);
    final entries = <String, DecryptedEventEntry>{};
    for (final record in records) {
      final value = record.value;
      if (value is String) {
        // Pre-0.2.0 schema: bare decrypted text without author.
        entries[record.key] = DecryptedEventEntry(
          pubkey: null,
          vCardText: value,
        );
      } else if (value is Map) {
        final vCardText = value['vcard'];
        if (vCardText is! String) continue;
        entries[record.key] = DecryptedEventEntry(
          pubkey: value['pubkey'] as String?,
          vCardText: vCardText,
        );
      }
    }
    return entries;
  }

  Future<void> deleteDecryptedEvents(Iterable<String> eventIds) {
    final ids = eventIds.toList(growable: false);
    if (ids.isEmpty) return Future.value();
    return _decryptedEvents.records(ids).delete(_database);
  }

  Future<void> clearComputed() {
    return _database.transaction((txn) async {
      await _contacts.delete(txn);
      await _contactIndex.delete(txn);
      await _uidEvents.delete(txn);
    });
  }

  Future<void> clearAll() {
    return _database.transaction((txn) async {
      await _decryptedEvents.delete(txn);
      await _contacts.delete(txn);
      await _contactIndex.delete(txn);
      await _uidEvents.delete(txn);
    });
  }

  Future<void> saveComputed({
    required List<AddressBookContact> contacts,
    required Map<({String pubkey, String uid}), List<String>> uidEvents,
  }) {
    return _database.transaction((txn) async {
      await _contacts.delete(txn);
      await _contactIndex.delete(txn);
      await _uidEvents.delete(txn);
      for (final contact in contacts) {
        final key = contactKey(pubkey: contact.pubKey, uid: contact.uid);
        await _contacts.record(key).put(txn, contact.toJson());
        await _contactIndex.record(key).put(txn, contact.index.toJson());
      }
      for (final entry in uidEvents.entries) {
        final key = contactKey(pubkey: entry.key.pubkey, uid: entry.key.uid);
        await _uidEvents.record(key).put(txn, {
          'pubkey': entry.key.pubkey,
          'uid': entry.key.uid,
          'eventIds': entry.value,
        });
      }
    });
  }

  Future<AddressBookContact?> getContact({
    required String pubkey,
    required String uid,
  }) async {
    final data = await _contacts
        .record(contactKey(pubkey: pubkey, uid: uid))
        .get(_database);
    if (data == null) return null;
    return AddressBookContact.fromJson(data);
  }

  Future<List<AddressBookContact>> list({ContactQuery? query}) async {
    final finder = Finder(
      sortOrders: [
        SortOrder('index.formattedName'),
        SortOrder('eventCreatedAt', false),
      ],
    );
    final records = await _contacts.find(_database, finder: finder);
    return _filter(
      records.map((record) => AddressBookContact.fromJson(record.value)),
      query,
    ).toList(growable: false);
  }

  Stream<List<AddressBookContact>> watchAll({ContactQuery? query}) {
    final finder = Finder(
      sortOrders: [
        SortOrder('index.formattedName'),
        SortOrder('eventCreatedAt', false),
      ],
    );
    return _contacts
        .query(finder: finder)
        .onSnapshots(_database)
        .map(
          (records) => _filter(
            records.map((record) => AddressBookContact.fromJson(record.value)),
            query,
          ).toList(growable: false),
        );
  }

  Stream<AddressBookContact?> watch({
    required String pubkey,
    required String uid,
  }) {
    return _contacts
        .record(contactKey(pubkey: pubkey, uid: uid))
        .onSnapshot(_database)
        .map((snapshot) {
          if (snapshot == null) return null;
          return AddressBookContact.fromJson(snapshot.value);
        });
  }

  Iterable<AddressBookContact> _filter(
    Iterable<AddressBookContact> contacts,
    ContactQuery? query,
  ) {
    final includeDeleted = query?.includeDeleted ?? false;
    final pubkey = query?.pubkey;
    final text = query?.text?.trim().toLowerCase();
    return contacts.where((contact) {
      if (!includeDeleted && contact.deleted) return false;
      if (pubkey != null && contact.pubKey != pubkey) return false;
      if (text == null || text.isEmpty) return true;
      final index = contact.index;
      final haystack = [
        contact.uid,
        index.formattedName,
        ...index.emails,
        ...index.phones,
        ...index.nostrIdentifiers,
        if (index.organization != null) index.organization!,
      ].join('\n').toLowerCase();
      return haystack.contains(text);
    });
  }
}
