# Nostr Address Book

Local-first Dart package for portable private Nostr address books.

Contacts are stored as vCard 4.0 payloads in addressable Nostr events:

- kind `38522`
- `d` tag equal to the vCard `UID`
- NIP-44 self-encrypted content by default
- NIP-09 deletion events for removals, addressed by `a` tag

A removal queues two events under one `created_at`: an empty version of the
contact event, then the deletion request. Relays honouring NIP-09 drop both.
Relays ignoring it are left serving the empty version rather than the encrypted
vCard.

## Usage

```dart
// Both shims are caller-owned and can be shared with the rest of the app. The
// package only enqueues address-book events into the queue, and only declares
// its own requests on the engine.
final broadcastQueue = OfflineBroadcast.withNdk(ndk, db: database);
final syncEngine = SyncEngine(ndk, db: database)..start();
final book = NostrAddressBook(
  ndk: ndk,
  database: database,
  broadcastQueue: broadcastQueue,
  syncEngine: syncEngine,
);

// Declared once, then kept up to date without a timer of your own.
await book.sync();

// Pull to refresh.
await book.refresh();

await book.upsertVCard(vcardText);
await book.delete(uid);

final contacts = await book.list();
final stream = book.watchAll();

await book.rebuildComputedStores();

broadcastQueue.retryNow();
broadcastQueue.start();

book.stopAllSync();
await broadcastQueue.dispose();
await syncEngine.dispose();
```

## Syncing

Downward sync is delegated to
[sync_engine_shim_for_ndk](https://pub.dev/packages/sync_engine_shim_for_ndk).
`sync()` declares the account's contact and deletion filters on its NIP-65 read
relays; the engine works out what is missing, fetches it into the NDK cache,
and revisits the recent end on its own. Nothing here paginates or tracks a
`since`.

The engine reports pages, never events, so each landed page is reconciled:
cached contact events with no decrypted entry yet are NIP-44 decrypted, stored,
and the computed stores are rebuilt. `reconcile()` runs that pass on demand,
for events that reached the cache through another path.

```dart
final handle = await book.sync();
syncEngine.watchStatus(handle).listen((status) => print(status.phase));

// Leaving the address-book screen: the engine stops spending network on it.
book.stopSync();
```

Requests authenticate as their own account (NIP-42), so an address book living
on a relay that serves it only to its owner syncs like any other. That account
must be in `ndk.accounts` and able to sign, otherwise the engine reads nothing
and reports a `SyncAuthUnavailable`.

New events land within the engine's `maxStaleness`, not the second they are
signed: the engine polls, it does not hold a subscription. `refresh()` is the
way to shorten that wait.

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

// Each account syncs under its own identity; reconciliation decrypts for the
// logged one, so the others materialize when they are back.
await book.sync(pubkey: otherPubkey);

// Logout: remove one account's local data (relays are untouched).
await broadcastQueue.clearLocalAccountData(pubkey: myPubkey);
await book.clearLocalAccountData(pubkey: myPubkey);

// Wipe every account's local address-book data.
await book.clearAllLocalData();
```

`clearLocalAccountData` clears, for that account only: raw decrypted entries,
its kind `38522` and address-book NIP-09 events in the NDK cache, and the sync
coverage of its filters, on every relay they were synced from.
`clearAllLocalData` does the same for every account. Coverage of requests other
packages declared on the same engine is never touched, and neither is the
caller-owned broadcast queue: clear it yourself through its own
`clearLocalAccountData`/`clearAllLocalData`, otherwise pending events are
eventually published.

Cache and coverage go together, which is why the clears forget: a cache emptied
under a coverage that survived is never fetched again.

`NostrAddressBook` uses `ndk.accounts` for signing and encryption. Local reads,
watchers, and computed-store rebuilds do not require a signer.

Sync resolves the account's NIP-65 read relays through `ndk.userRelayLists`.
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
