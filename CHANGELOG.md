## 0.4.0

- `delete` publishes an empty version of the contact event alongside the NIP-09
  deletion request, both stamped with the same `created_at`. A relay honouring
  NIP-09 drops the two and keeps nothing; a relay ignoring it still replaces the
  contact with the empty version and stops serving the encrypted vCard.
- The deletion request no longer carries an `e` tag. For an addressable kind the
  `a` tag already covers every version up to the deletion timestamp, while an
  `e` tag names a single version that may be stale by the time it is written.
- Deletions read from relays keep the two tag forms apart, as NIP-09 defines
  them: an `e` tag deletes the one event it names, an `a` tag every version up
  to its own `created_at`, that timestamp included. A contact and its deletion
  sharing one second are now resolved as deleted, and deleting a superseded
  version by id no longer takes the current one down with it.
- Breaking: downward sync moves to `sync_engine_shim_for_ndk`. The constructor
  requires a caller-owned `syncEngine`, shareable with the rest of the app like
  the broadcast queue. The engine works out what is missing, fetches it into
  the NDK cache, and revisits the recent end on its own, so the app has no
  pagination, no `since` tracking and no polling left to write.
- Breaking: `fetchRecent()`, `pull()`, `recentFilters()`, `recentLimit` and
  `AddressBookFilters` are gone. `sync({pubkey})` declares an account's sync
  and returns its handle, `refresh()` is the pull to refresh gesture,
  `reconcile()` turns cached events into contacts, `stopSync`/`stopAllSync`
  drop the package's interest, and `syncRequest({pubkey})` exposes what was
  declared.
- Breaking: `AddressBookSyncResult.fetchedEvents` is gone; the engine reports
  pages, not events. The remaining counters cover reconciliation, background
  passes included.
- Breaking: `contactFilter` and `deletionFilter` lose `limit` and `uid`. The
  engine ignores a filter `limit`, and a window is declared through
  `since`/`until`.
- Sync requests authenticate as their own account (NIP-42), so an address book
  a relay serves only to its owner syncs like any other.
- `clearLocalAccountData` and `clearAllLocalData` forget the sync coverage of
  the address book's own filters instead of clearing NDK fetched ranges
  globally, so other consumers no longer re-download. Coverage goes on every
  relay a filter was synced from, current NIP-65 list or not: a cache emptied
  under a coverage that survived is never fetched again.
- Breaking: require `ndk: ^0.10.0-dev.1` and Dart SDK `^3.12.2`, which
  `sync_engine_shim_for_ndk: ^0.7.0` pulls in.

## 0.3.1

- Widen the ndk constraint to `>=0.9.2 <0.11.0`, so an app already on the
  ndk `0.10` prerelease series can depend on this package. Requires
  `broadcast_queue_shim_for_ndk: ^0.5.1`, which widened its own constraint the
  same way. No API change.

## 0.3.0

- Breaking: require `ndk: ^0.9.2` and `broadcast_queue_shim_for_ndk: ^0.5.0`.
  Both the `Ndk` instance and the broadcast queue are caller-owned, so the app
  has to move to ndk `0.9` as well.

## 0.2.0

- Add `clearLocalAccountData({required String pubkey})` and
  `clearAllLocalData()`. They clear the raw and computed stores, kind `38522`
  and address-book NIP-09 events in the NDK cache, and NDK fetched-range
  records so later pulls re-download. The caller-owned broadcast queue is
  never touched: clear it through its own `clearLocalAccountData` /
  `clearAllLocalData` at logout.
- Support several accounts in one database: computed stores are keyed by
  `pubkey:uid`, NIP-09 deletions only apply to contacts of their own author,
  and `ContactQuery.pubkey` filters `list`/`watchAll`.
- Breaking: the constructor now requires a caller-owned `broadcastQueue`
  (`OfflineBroadcast`), shareable with the rest of the app. `dispose()` is
  removed: dispose the queue yourself. Depend on
  `broadcast_queue_shim_for_ndk` directly to construct the queue.
- Breaking: `get` and `watch` target the current account by default and take
  an optional `pubkey`. Call `rebuildComputedStores()` once after upgrading so
  computed stores are re-keyed.
- Store the owning account in raw decrypted entries. Pre-0.2.0 entries are
  rewritten with their author during rebuild while their encrypted event is
  still cached.
- Attribute queued broadcasts to the signing account, so account-scoped queue
  clears work and `broadcastQueue.get`/`watch` lookups take the `pubkey`
  argument.
- Bump `broadcast_queue_shim_for_ndk` to `^0.4.0`.

## 0.1.1

- Ensure address-book upsert and delete events are signed before they are saved
  or queued for offline broadcast.
- Rename relay accessor methods to `getReadRelays` and `getWriteRelays`.
- Bump `ndk` to `^0.8.4-dev.5`.

## 0.1.0

- Initial version.
