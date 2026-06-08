class NostrAddressBookException implements Exception {
  final String message;
  final Object? cause;

  const NostrAddressBookException(this.message, [this.cause]);

  @override
  String toString() {
    if (cause == null) return 'NostrAddressBookException: $message';
    return 'NostrAddressBookException: $message ($cause)';
  }
}

class AddressBookAccountException extends NostrAddressBookException {
  const AddressBookAccountException(super.message, [super.cause]);
}

class AddressBookVCardException extends NostrAddressBookException {
  const AddressBookVCardException(super.message, [super.cause]);
}

class AddressBookCryptoException extends NostrAddressBookException {
  const AddressBookCryptoException(super.message, [super.cause]);
}
