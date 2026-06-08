# Nostr Address Book

Local-first Dart package for portable private Nostr address books.

Contacts are stored as vCard 4.0 payloads in addressable Nostr events:

- kind `38522`
- `d` tag equal to the vCard `UID`
- NIP-44 self-encrypted content by default
- NIP-09 deletion events for removals

## Usage

```dart
final book = NostrAddressBook(
  ndk: ndk,
  database: database,
);

await book.fetchRecent();
await book.pull(paginate: true);

await book.upsertVCard(vcardText);
await book.delete(uid);

final contacts = await book.list();
final stream = book.watchAll();

await book.rebuildComputedStores();

book.broadcastQueue.retryNow();
book.broadcastQueue.start();

await book.dispose();
```

`NostrAddressBook` uses `ndk.accounts` for signing and encryption. Local reads,
watchers, and computed-store rebuilds do not require a signer.

Network fetches resolve the current user's NIP-65 read relays through
`ndk.userRelayLists` and pass them explicitly to `ndk.requests.query`.
Publishing resolves NIP-65 write relays the same way before queueing events in
`broadcastQueue`.

## Storage

The package keeps raw and computed data separate:

- NDK cache: encrypted Nostr events.
- `address_book_decrypted_events`: `eventId -> decryptedText`.
- `address_book_contacts`, `address_book_contact_index`, and
  `address_book_uid_events`: computed stores that can be dropped and rebuilt.

`rebuildComputedStores()` reconstructs contacts from the NDK cache and decrypted
event store without internet or signer access.
