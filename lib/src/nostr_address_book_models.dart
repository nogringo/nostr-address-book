import 'package:ndk/ndk.dart';

enum AddressBookContactStatus { active, deleted }

class ContactIndex {
  final String formattedName;
  final List<String> emails;
  final List<String> phones;
  final List<String> nostrIdentifiers;
  final List<String> photoUris;
  final String? organization;
  final String? revision;

  const ContactIndex({
    required this.formattedName,
    this.emails = const [],
    this.phones = const [],
    this.nostrIdentifiers = const [],
    this.photoUris = const [],
    this.organization,
    this.revision,
  });

  factory ContactIndex.fromJson(Map<String, Object?> json) {
    return ContactIndex(
      formattedName: json['formattedName'] as String? ?? '',
      emails: _stringList(json['emails']),
      phones: _stringList(json['phones']),
      nostrIdentifiers: _stringList(json['nostrIdentifiers']),
      photoUris: _stringList(json['photoUris']),
      organization: json['organization'] as String?,
      revision: json['revision'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'formattedName': formattedName,
      'emails': emails,
      'phones': phones,
      'nostrIdentifiers': nostrIdentifiers,
      'photoUris': photoUris,
      'organization': organization,
      'revision': revision,
    };
  }
}

class AddressBookContact {
  final String uid;
  final String vCard;
  final ContactIndex index;
  final String eventId;
  final int eventCreatedAt;
  final String pubKey;
  final AddressBookContactStatus status;

  const AddressBookContact({
    required this.uid,
    required this.vCard,
    required this.index,
    required this.eventId,
    required this.eventCreatedAt,
    required this.pubKey,
    this.status = AddressBookContactStatus.active,
  });

  bool get deleted => status == AddressBookContactStatus.deleted;

  factory AddressBookContact.fromJson(Map<String, Object?> json) {
    return AddressBookContact(
      uid: json['uid'] as String,
      vCard: json['vCard'] as String? ?? '',
      index: ContactIndex.fromJson(
        (json['index'] as Map?)?.cast<String, Object?>() ?? const {},
      ),
      eventId: json['eventId'] as String? ?? '',
      eventCreatedAt: json['eventCreatedAt'] as int? ?? 0,
      pubKey: json['pubKey'] as String? ?? '',
      status:
          (json['status'] as String?) == AddressBookContactStatus.deleted.name
          ? AddressBookContactStatus.deleted
          : AddressBookContactStatus.active,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'uid': uid,
      'vCard': vCard,
      'index': index.toJson(),
      'eventId': eventId,
      'eventCreatedAt': eventCreatedAt,
      'pubKey': pubKey,
      'status': status.name,
    };
  }
}

class ContactQuery {
  final String? text;
  final bool includeDeleted;

  const ContactQuery({this.text, this.includeDeleted = false});
}

class AddressBookSyncResult {
  final int fetchedEvents;
  final int decryptedEvents;
  final int skippedEvents;
  final int computedContacts;

  const AddressBookSyncResult({
    required this.fetchedEvents,
    required this.decryptedEvents,
    required this.skippedEvents,
    required this.computedContacts,
  });
}

class AddressBookFilters {
  final Filter contacts;
  final Filter deletions;

  const AddressBookFilters({required this.contacts, required this.deletions});
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value.whereType<String>().toList(growable: false);
}
