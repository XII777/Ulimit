import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart';
import '../core/native/usage_events_channel.dart';
import 'db/app_database.dart';
import 'doomscroll_apps.dart';
import 'screen_time_filter.dart';

/// Bridges native foreground-app events into real Drift rows. Started
/// once at app launch (see main.dart) and lives for the app's process
/// lifetime.
///
/// Model: on every new foreground event, attribute the elapsed time
/// since the *previous* event to the *previous* package — i.e. "how
/// long was the last app actually in front of the user." The very
/// first event in a session has nothing to attribute yet, so it's
/// stored and only resolved once the next transition arrives.
///
/// Known simplification: if a session spans midnight, the elapsed time
/// is attributed entirely to the day of the earlier timestamp rather
/// than split across the boundary. Acceptable for a v1 — the error is
/// bounded by one app's single foreground duration, not compounding.
class UsageTracker {
  UsageTracker(this._db, {Future<void> Function()? onAccessibilityReady})
      : _onAccessibilityReady = onAccessibilityReady;

  /// The most recent foreground transition, exposed for the live
  /// screen-time counter: while an app is in front, its un-attributed
  /// elapsed time grows by the second on top of the persisted total.
  static final ValueNotifier<({String package, int sinceMillis})?> liveForeground =
      ValueNotifier(null);

  /// Broadcast view of [liveForeground] for stream-based consumers
  /// (riverpod providers). Replays the current value on listen.
  static Stream<({String package, int sinceMillis})> get liveForegroundStream {
    late StreamController<({String package, int sinceMillis})> controller;
    void listener() {
      final v = liveForeground.value;
      if (v != null) controller.add(v);
    }

    controller = StreamController.broadcast(
      onListen: listener,
      onCancel: () => liveForeground.removeListener(listener),
    );
    liveForeground.addListener(listener);
    return controller.stream;
  }

  /// Invoked the moment the accessibility service connects (it emits a
  /// sentinel event). Used to re-push the native policy snapshot so
  /// native always has the LATEST restrictions — even when the service
  /// was enabled from outside the normal app flow (OS settings, the
  /// recovery screen after an app update).
  final Future<void> Function()? _onAccessibilityReady;

  final AppDatabase _db;
  StreamSubscription<ForegroundEvent>? _sub;

  String? _pendingPackage;
  int? _pendingTimestampMillis;

  void start() {
    _sub = UsageEventsChannel.stream.listen(_onEvent, onError: (_) {
      // Accessibility service not enabled yet, or channel not ready —
      // fail silently rather than crash the app; permission screens
      // surface the "not granted" state explicitly elsewhere.
    });
  }

  void dispose() => _sub?.cancel();

  Future<void> _onEvent(ForegroundEvent event) async {
    final now = event.timestampMillis;

    // Sentinel from the accessibility service on connect: refresh the
    // native policy snapshot, then drop it (never a real package).
    if (event.packageName == UlimitSentinel.accessibilityReady) {
      await _onAccessibilityReady?.call();
      return;
    }

    if (_pendingPackage != null && _pendingTimestampMillis != null) {
      // floor(), matching the live counter: the DB row becomes the
      // authoritative total only for whole elapsed seconds, and the
      // live "pending" display shows the same fraction. round() here
      // would hand the DB a second the live view already showed,
      // double-counting it on the next switch.
      final elapsedSeconds = ((now - _pendingTimestampMillis!) / 1000).floor();
      if (elapsedSeconds > 0 && elapsedSeconds < 6 * 3600) {
        // Discard >6h gaps — almost certainly a phone-asleep period the
        // OS didn't cleanly signal, not real foreground time.
        await _addUsage(_pendingPackage!, _pendingTimestampMillis!, elapsedSeconds);
      }
      // A genuine app switch (not the same package re-firing) is what
      // "pickups" counts.
      if (_pendingPackage != event.packageName) {
        await _incrementPickup(now);
        // Every distinct foreground entry into a doomscroll app is one
        // "reel/shorts session" — the count the doomscroll feature's
        // budgets and analytics are built on.
        if (kDoomscrollPackages.contains(event.packageName)) {
          await _incrementOpenCount(event.packageName, now);
        }
      }
    } else if (_pendingPackage == null) {
      // Very first event of the session: nothing to attribute yet, and
      // no prior app to switch FROM — picking up the phone from the
      // launcher is a pickup, but a cold start into an app is not.
      await _incrementPickup(now);
      if (kDoomscrollPackages.contains(event.packageName)) {
        await _incrementOpenCount(event.packageName, now);
      }
    }

    _pendingPackage = event.packageName;
    _pendingTimestampMillis = now;
    liveForeground.value = (package: event.packageName, sinceMillis: now);
  }

  Future<void> _addUsage(String package, int atMillis, int seconds) async {
    // Never persist home-screen/launcher, system-UI or Ulimit time as
    // app usage — screen time counts opened apps only.
    if (isExcludedFromScreenTime(package)) return;
    final day = _truncateToDay(DateTime.fromMillisecondsSinceEpoch(atMillis));
    // Real upsert leaning on the (packageName, day) unique key from the
    // schema: insert a fresh row, or atomically add to the existing
    // one's foreground_seconds. One statement, no read-then-write race.
    await _db.customStatement(
      '''
      INSERT INTO app_usage (package_name, day, foreground_seconds)
      VALUES (?, ?, ?)
      ON CONFLICT(package_name, day)
      DO UPDATE SET foreground_seconds = foreground_seconds + excluded.foreground_seconds
      ''',
      // Drift stores DateTimeColumn as unix *seconds* by default —
      // this raw customStatement bypasses Drift's automatic conversion,
      // so it must match that convention by hand or every typed read
      // elsewhere in the app silently never matches what gets written here.
      [package, day.millisecondsSinceEpoch ~/ 1000, seconds],
    );
  }

  Future<void> _incrementPickup(int atMillis) async {
    final day = _truncateToDay(DateTime.fromMillisecondsSinceEpoch(atMillis));
    final existing = await (_db.select(_db.pickupsLog)..where((t) => t.day.equals(day)))
        .getSingleOrNull();
    if (existing == null) {
      await _db.into(_db.pickupsLog).insert(PickupsLogCompanion.insert(day: day, count: const Value(1)));
    } else {
      await (_db.update(_db.pickupsLog)..where((t) => t.day.equals(day)))
          .write(PickupsLogCompanion(count: Value(existing.count + 1)));
    }
  }

  /// Bumps today's open count for a doomscroll app (upsert on the
  /// AppUsage unique key). Deliberately NOT gated by
  /// isExcludedFromScreenTime — the preset never contains launchers.
  Future<void> _incrementOpenCount(String package, int atMillis) async {
    final day = _truncateToDay(DateTime.fromMillisecondsSinceEpoch(atMillis));
    await _db.customStatement(
      '''
      INSERT INTO app_usage (package_name, day, foreground_seconds, open_count)
      VALUES (?, ?, 0, 1)
      ON CONFLICT(package_name, day)
      DO UPDATE SET open_count = open_count + 1
      ''',
      [package, day.millisecondsSinceEpoch ~/ 1000],
    );
  }

  DateTime _truncateToDay(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
}

/// The live foreground app, mirrored from [UsageTracker.liveForeground]
/// into riverpod — read by the Focus-indicator chip sync (doomscroll
/// counting) and the doomscroll screen's "scrolling" badge. Replays
/// the current value immediately on subscribe.
final liveForegroundProvider = StreamProvider<({String package, int sinceMillis})>((ref) {
  return UsageTracker.liveForegroundStream;
});
