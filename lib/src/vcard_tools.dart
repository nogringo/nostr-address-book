import 'package:uuid/uuid.dart';
import 'package:vcard_dart/vcard_dart.dart';

import 'nostr_address_book_exception.dart';
import 'nostr_address_book_models.dart';

class CanonicalVCard {
  final String uid;
  final String text;
  final VCard parsed;
  final ContactIndex index;

  const CanonicalVCard({
    required this.uid,
    required this.text,
    required this.parsed,
    required this.index,
  });
}

class VCardTools {
  static const _uuid = Uuid();
  static const _parser = VCardParser(lenient: false, preserveRaw: true);

  static CanonicalVCard parseAndNormalize(String text) {
    final parsed = _parseSingle(text);
    if (parsed.version != VCardVersion.v40) {
      throw const AddressBookVCardException('vCard VERSION must be 4.0');
    }
    if (parsed.formattedName.trim().isEmpty) {
      throw const AddressBookVCardException('vCard FN is required');
    }

    final uid = _ensureUid(parsed.uid);
    final normalized = _withCanonicalLineEndings(
      parsed.uid == null || parsed.uid!.trim().isEmpty
          ? _insertUid(text, uid)
          : text,
    );
    final reparsed = _parseSingle(normalized);
    if (reparsed.uid != uid) {
      throw const AddressBookVCardException(
        'vCard UID could not be normalized',
      );
    }

    return CanonicalVCard(
      uid: uid,
      text: normalized,
      parsed: reparsed,
      index: buildIndex(reparsed),
    );
  }

  static CanonicalVCard parseExisting(String text) {
    final parsed = _parseSingle(text);
    if (parsed.version != VCardVersion.v40) {
      throw const AddressBookVCardException('vCard VERSION must be 4.0');
    }
    final uid = parsed.uid?.trim();
    if (uid == null || uid.isEmpty) {
      throw const AddressBookVCardException('vCard UID is required');
    }
    return CanonicalVCard(
      uid: uid,
      text: _withCanonicalLineEndings(text),
      parsed: parsed,
      index: buildIndex(parsed),
    );
  }

  static ContactIndex buildIndex(VCard vcard) {
    final organization = vcard.organization?.toFormattedString();
    return ContactIndex(
      formattedName: vcard.formattedName,
      emails: _unique(vcard.emails.map((email) => email.address)),
      phones: _unique(vcard.telephones.map((tel) => tel.number)),
      nostrIdentifiers: _unique(
        vcard.impps
            .map((impp) => impp.uri)
            .where((uri) => uri.toLowerCase().startsWith('nostr:')),
      ),
      photoUris: _unique(
        vcard.photos.where((photo) => photo.isUri).map((photo) => photo.uri!),
      ),
      organization: organization != null && organization.isNotEmpty
          ? organization
          : null,
      revision: vcard.revision?.toString(),
    );
  }

  static VCard _parseSingle(String text) {
    try {
      return _parser.parseSingle(text);
    } on Object catch (error) {
      throw AddressBookVCardException('Invalid vCard', error);
    }
  }

  static String _ensureUid(String? uid) {
    final trimmed = uid?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return 'urn:uuid:${_uuid.v4()}';
  }

  static String _insertUid(String text, String uid) {
    final lines = _withCanonicalLineEndings(text).split('\r\n');
    final versionIndex = lines.indexWhere(
      (line) => line.toUpperCase() == 'VERSION:4.0',
    );
    if (versionIndex < 0) {
      throw const AddressBookVCardException('vCard VERSION:4.0 is required');
    }
    lines.insert(versionIndex + 1, 'UID:$uid');
    return lines.join('\r\n');
  }

  static String _withCanonicalLineEndings(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return normalized.trim().split('\n').join('\r\n');
  }

  static List<String> _unique(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) continue;
      if (seen.add(trimmed.toLowerCase())) result.add(trimmed);
    }
    return result;
  }
}
