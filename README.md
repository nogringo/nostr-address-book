# Nostr Address Book

Local-first Dart package for portable private Nostr address books.

Contacts are stored as vCard 4.0 payloads in addressable Nostr events:

- kind `38522`
- `d` tag equal to the vCard `UID`
- NIP-44 self-encrypted content by default
- NIP-09 deletion events for removals

## Usage

```dart
// The broadcast queue is caller-owned and can be shared with the rest of the
// app; the package only enqueues address-book events into it.
final broadcastQueue = OfflineBroadcast.withNdk(ndk, db: database);
final book = NostrAddressBook(
  ndk: ndk,
  database: database,
  broadcastQueue: broadcastQueue,
);

await book.fetchRecent();
await book.pull(paginate: true);

await book.upsertVCard(vcardText);
await book.delete(uid);

final contacts = await book.list();
final stream = book.watchAll();

await book.rebuildComputedStores();

broadcastQueue.retryNow();
broadcastQueue.start();

await broadcastQueue.dispose();
```

## Multiple accounts

Several accounts can share one database. Computed contacts are keyed per
account, so identical vCard UIDs owned by different accounts do not collide,
and NIP-09 deletions only apply to contacts of their own author.

```dart
// get/watch default to the current account; pass pubkey to target another.
final mine = await book.get(uid);
final theirs = await book.get(uid, pubkey: otherPubkey);

// list/watchAll span every account unless the query narrows them.
final onlyMine = await book.list(query: ContactQuery(pubkey: myPubkey));

// Logout: remove one account's local data (relays are untouched).
await broadcastQueue.clearLocalAccountData(pubkey: myPubkey);
await book.clearLocalAccountData(pubkey: myPubkey);

// Wipe every account's local address-book data.
await book.clearAllLocalData();
```

`clearLocalAccountData` clears, for that account only: raw decrypted entries,
its kind `38522` and address-book NIP-09 events in the NDK cache, and its NDK
fetched-range records. `clearAllLocalData` empties the package stores, removes
address-book events from the NDK cache, and clears NDK fetched-range records
globally. Neither touches the caller-owned broadcast queue: clear it yourself
through its own `clearLocalAccountData`/`clearAllLocalData`, otherwise pending
events are eventually published.

`NostrAddressBook` uses `ndk.accounts` for signing and encryption. Local reads,
watchers, and computed-store rebuilds do not require a signer.

Network fetches resolve the current user's NIP-65 read relays through
`ndk.userRelayLists` and pass them explicitly to `ndk.requests.query`.
Publishing resolves NIP-65 write relays the same way before queueing events in
`broadcastQueue`.

## Storage

The package keeps raw and computed data separate:

- NDK cache: encrypted Nostr events.
- `address_book_decrypted_events`: `eventId -> {pubkey, vcard}`.
- `address_book_contacts`, `address_book_contact_index`, and
  `address_book_uid_events`: computed stores keyed by `pubkey:uid` that can be
  dropped and rebuilt.

`rebuildComputedStores()` reconstructs contacts from the NDK cache and decrypted
event store without internet or signer access.
