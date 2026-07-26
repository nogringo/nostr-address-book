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
