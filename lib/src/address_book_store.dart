import 'package:sembast/sembast.dart';

import 'nostr_address_book_models.dart';

class AddressBookStore {
  static const decryptedEventsName = 'address_book_decrypted_events';
  static const contactsName = 'address_book_contacts';
  static const contactIndexName = 'address_book_contact_index';
  static const uidEventsName = 'address_book_uid_events';

  final Database _database;
  final StoreRef<String, String> _decryptedEvents;
  final StoreRef<String, Map<String, Object?>> _contacts;
  final StoreRef<String, Map<String, Object?>> _contactIndex;
  final StoreRef<String, Map<String, Object?>> _uidEvents;

  AddressBookStore(Database database)
    : _database = database,
      _decryptedEvents = StoreRef<String, String>(decryptedEventsName),
      _contacts = stringMapStoreFactory.store(contactsName),
      _contactIndex = stringMapStoreFactory.store(contactIndexName),
      _uidEvents = stringMapStoreFactory.store(uidEventsName);

  Future<void> saveDecryptedEvent(String eventId, String decryptedText) {
    return _decryptedEvents.record(eventId).put(_database, decryptedText);
  }

  Future<Map<String, String>> loadAllDecryptedEvents() async {
    final records = await _decryptedEvents.find(_database);
    return {for (final record in records) record.key: record.value};
  }

  Future<void> clearComputed() {
    return _database.transaction((txn) async {
      await _contacts.delete(txn);
      await _contactIndex.delete(txn);
      await _uidEvents.delete(txn);
    });
  }

  Future<void> saveComputed({
    required List<AddressBookContact> contacts,
    required Map<String, List<String>> uidEvents,
  }) {
    return _database.transaction((txn) async {
      await _contacts.delete(txn);
      await _contactIndex.delete(txn);
      await _uidEvents.delete(txn);
      for (final contact in contacts) {
        await _contacts.record(contact.uid).put(txn, contact.toJson());
        await _contactIndex
            .record(contact.uid)
            .put(txn, contact.index.toJson());
      }
      for (final entry in uidEvents.entries) {
        await _uidEvents.record(entry.key).put(txn, {
          'uid': entry.key,
          'eventIds': entry.value,
        });
      }
    });
  }

  Future<AddressBookContact?> getContact(String uid) async {
    final data = await _contacts.record(uid).get(_database);
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

  Stream<AddressBookContact?> watch(String uid) {
    return _contacts.record(uid).onSnapshot(_database).map((snapshot) {
      if (snapshot == null) return null;
      return AddressBookContact.fromJson(snapshot.value);
    });
  }

  Iterable<AddressBookContact> _filter(
    Iterable<AddressBookContact> contacts,
    ContactQuery? query,
  ) {
    final includeDeleted = query?.includeDeleted ?? false;
    final text = query?.text?.trim().toLowerCase();
    return contacts.where((contact) {
      if (!includeDeleted && contact.deleted) return false;
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
