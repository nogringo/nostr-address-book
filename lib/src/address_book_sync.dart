import 'dart:async';

import 'package:ndk/ndk.dart';
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';

import 'nostr_address_book_models.dart';

/// What the reconciliation passes of one account add up to while a caller is
/// waiting on them.
class SyncTally {
  int holders = 0;
  int decrypted = 0;
  int skipped = 0;
  int computed = 0;
  Object? error;
  StackTrace? stackTrace;
}

class SyncRegistration {
  final SyncHandle handle;
  final List<String> relays;
  final StreamSubscription<SyncRequestStatus> subscription;

  /// The last page reconciled, so a status re-emitting it does not rebuild
  /// everything a second time.
  SyncProgress? lastProgress;

  SyncRegistration({
    required this.handle,
    required this.relays,
    required this.subscription,
  });
}

/// Drives the sync engine for the address book: one request per account, a
/// reconciliation behind every page that lands, and the coverage forgotten
/// when an account's local data goes.
///
/// It knows nothing of vCards, NDK accounts or the local stores. [requestOf]
/// builds an account's request, and [reconcileOf] turns what landed into
/// contacts, returning `null` when that account cannot be reconciled right
/// now, typically because it is not logged in.
class AddressBookSync {
  final SyncEngine engine;
  final Future<SyncRequest> Function(String pubkey) requestOf;
  final Future<AddressBookSyncResult?> Function(String pubkey) reconcileOf;

  final Map<String, SyncRegistration> _registrations = {};
  final Map<String, Future<void>> _declaring = {};
  final Map<String, Future<void>> _reconciling = {};
  final Set<String> _reconcileAgain = {};
  final Map<String, SyncTally> _tallies = {};

  AddressBookSync({
    required this.engine,
    required this.requestOf,
    required this.reconcileOf,
  });

  /// The accounts whose request is currently declared.
  Iterable<String> get declaredAccounts => _registrations.keys;

  /// Declares [pubkey]'s request and keeps it reconciled.
  ///
  /// Cheap to call again: the same handle comes back unless the request now
  /// names other relays, in which case the previous one is released first.
  Future<SyncHandle> declare(String pubkey) {
    // Serialized per account: two declarations racing would register the same
    // request twice and leave a holder no release can match.
    final pass = (_declaring[pubkey] ?? Future<void>.value()).then(
      (_) => _declare(pubkey),
    );
    _declaring[pubkey] = pass.then((_) {}, onError: (_) {});
    return pass;
  }

  /// Fetches [pubkey] now, however fresh its coverage is, then reconciles.
  Future<AddressBookSyncResult> refresh(String pubkey) async {
    final handle = await declare(pubkey);
    return _tallied(pubkey, () async {
      await engine.refresh(handle);
      await reconcileQuietly(pubkey);
    });
  }

  /// Reconciles [pubkey] and reports what every pass made of it.
  Future<AddressBookSyncResult> reconcile(String pubkey) {
    return _tallied(pubkey, () => reconcileQuietly(pubkey));
  }

  /// Reconciles [pubkey] without surfacing anything: this runs behind a landed
  /// page, where the next page is the retry. Passes are serialized per
  /// account, and one asked while another runs is honoured after it.
  Future<void> reconcileQuietly(String pubkey) {
    final running = _reconciling[pubkey];
    if (running != null) {
      _reconcileAgain.add(pubkey);
      return running;
    }
    final pass = _reconcileLoop(pubkey);
    _reconciling[pubkey] = pass;
    return pass;
  }

  /// Drops the interest in [pubkey]'s request. What was synced stays, and so
  /// does its coverage.
  void release(String pubkey) {
    final registration = _registrations.remove(pubkey);
    if (registration == null) return;
    unawaited(registration.subscription.cancel());
    engine.release(registration.handle);
  }

  void releaseAll() {
    for (final pubkey in _registrations.keys.toList(growable: false)) {
      release(pubkey);
    }
  }

  /// Releases [pubkey] and forgets the coverage of [filters], on every relay
  /// they were synced from rather than on the relays the request names today:
  /// a cache emptied under a coverage that survived is never fetched again.
  Future<void> forget(String pubkey, List<Filter> filters) async {
    release(pubkey);
    for (final filter in filters) {
      await engine.forgetFilter(filter, authPubkey: pubkey);
    }
  }

  Future<SyncHandle> _declare(String pubkey) async {
    final request = await requestOf(pubkey);
    final existing = _registrations[pubkey];
    if (existing != null) {
      if (_sameRelays(existing.relays, request.relays)) return existing.handle;
      release(pubkey);
    }

    final handle = engine.ensure(request);
    late final SyncRegistration registration;
    registration = SyncRegistration(
      handle: handle,
      relays: request.relays,
      subscription: engine.watchStatus(handle).listen((status) {
        final progress = status.progress;
        if (progress == null || progress.eventCount == 0) return;
        if (identical(progress, registration.lastProgress)) return;
        registration.lastProgress = progress;
        unawaited(reconcileQuietly(pubkey));
      }),
    );
    _registrations[pubkey] = registration;
    return handle;
  }

  /// Runs [body] while every reconciliation pass of [pubkey] adds up into one
  /// result, so a caller sees the pages that landed behind its back too.
  Future<AddressBookSyncResult> _tallied(
    String pubkey,
    Future<void> Function() body,
  ) async {
    final tally = _tallies.putIfAbsent(pubkey, SyncTally.new);
    tally.holders++;
    try {
      await body();
      final error = tally.error;
      if (error != null) {
        Error.throwWithStackTrace(
          error,
          tally.stackTrace ?? StackTrace.current,
        );
      }
      return AddressBookSyncResult(
        decryptedEvents: tally.decrypted,
        skippedEvents: tally.skipped,
        computedContacts: tally.computed,
      );
    } finally {
      tally.holders--;
      if (tally.holders == 0) _tallies.remove(pubkey);
    }
  }

  Future<void> _reconcileLoop(String pubkey) async {
    try {
      do {
        _reconcileAgain.remove(pubkey);
        final result = await reconcileOf(pubkey);
        if (result == null) return;
        final tally = _tallies[pubkey];
        if (tally != null) {
          tally.decrypted += result.decryptedEvents;
          tally.skipped += result.skippedEvents;
          tally.computed = result.computedContacts;
        }
      } while (_reconcileAgain.contains(pubkey));
    } catch (error, stackTrace) {
      // A caller waiting on this pass gets the error; behind a landed page
      // there is nobody to tell, and the next page reconciles again.
      final tally = _tallies[pubkey];
      tally?.error ??= error;
      tally?.stackTrace ??= stackTrace;
    } finally {
      _reconciling.remove(pubkey);
      _reconcileAgain.remove(pubkey);
    }
  }

  bool _sameRelays(List<String> a, List<String> b) {
    return a.length == b.length && a.toSet().containsAll(b);
  }
}
