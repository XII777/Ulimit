import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/diagnostics/diagnostics_log.dart';
import '../core/native/usage_events_channel.dart';
import 'db/app_database.dart';
import 'doomscroll_apps.dart';
import 'screen_time_filter.dart';

/// One live foreground session, mirrored to the UI while the app is in
/// front. [osSecondsAtSessionStart] snapshots the row's OS column the
/// moment the session began — the live counter needs it to know how
/// much of the ongoing session the OS sync has already committed to the
/// database (adding the full elapsed time on top of that committed part
/// is exactly what double-counted the current session).
class LiveForegroundSession {
  const LiveForegroundSession({
    required this.package,
    required this.sinceMillis,
    this.osSecondsAtSessionStart,
  });

  final String package;
  final int sinceMillis;

  /// Merged OS-column value for this package today, read right after
  /// the session started. Null until the async snapshot read lands
  /// (~one tick) — consumers must not guess while it is null.
  final int? osSecondsAtSessionStart;

  LiveForegroundSession withSnapshot(int osSeconds) => LiveForegroundSession(
        package: package,
        sinceMillis: sinceMillis,
        osSecondsAtSessionStart: osSeconds,
      );

  bool isSameSession(String package, int sinceMillis) =>
      this.package == package && this.sinceMillis == sinceMillis;
}

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
/// The open session is also closed by two sentinels that fire without a
/// window event: screen-off (Digital Wellbeing stops counting the
/// moment the screen goes off — the framework pauses the resumed
/// activity — and accessibility gets no event for that) and the
/// accessibility service unbinding (no further events will come, so the
/// pending session is dropped rather than left growing).
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
  /// elapsed time grows by the second on top of the persisted total
  /// (minus whatever the OS sync already committed — see
  /// [LiveForegroundSession.osSecondsAtSessionStart]).
  static final ValueNotifier<LiveForegroundSession?> liveForeground =
      ValueNotifier(null);

  /// Broadcast view of [liveForeground] for stream-based consumers
  /// (riverpod providers). Replays the current value on listen.
  static Stream<LiveForegroundSession> get liveForegroundStream {
    late StreamController<LiveForegroundSession> controller;
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
    instance = this;
    _sub = UsageEventsChannel.stream.listen(_onEvent, onError: (_) {
      // Accessibility service not enabled yet, or channel not ready —
      // fail silently rather than crash the app; permission screens
      // surface the "not granted" state explicitly elsewhere.
    });
  }

  void dispose() => _sub?.cancel();

  // --- diagnostics-visible state (read by the report builder) ----------

  /// The process has exactly one tracker (started at app launch); the
  /// report builder reaches its attribution state through here.
  static UsageTracker? instance;

  /// Open attribution window: the package whose foreground time is
  /// being accumulated and when its session began.
  String? get pendingPackage => _pendingPackage;
  int? get pendingTimestampMillis => _pendingTimestampMillis;

  static DateTime? lastEventAt;
  static DateTime? lastScreenOffAt;
  static DateTime? lastScreenOnAt;
  static DateTime? accessibilityReadyAt;
  static DateTime? accessibilityDownAt;
  static int eventsSeen = 0;

  Future<void> _onEvent(ForegroundEvent event) async {
    final now = event.timestampMillis;
    eventsSeen++;
    lastEventAt = DateTime.fromMillisecondsSinceEpoch(now);

    // Sentinel from the accessibility service on connect: refresh the
    // native policy snapshot, then drop it (never a real package).
    if (event.packageName == UlimitSentinel.accessibilityReady) {
      accessibilityReadyAt = DateTime.now();
      await _onAccessibilityReady?.call();
      DiagnosticsLog.record('accessibility service connected', tag: 'usage');
      return;
    }

    // Accessibility service unbound (disabled / reclaimed by the OS).
    // No further events will arrive — drop the open session instead of
    // letting its pending counter grow forever. No attribution: the OS
    // sync owns the truth for whatever happened while tracking was off.
    if (event.packageName == UlimitSentinel.accessibilityDown) {
      accessibilityDownAt = DateTime.now();
      _pendingPackage = null;
      _pendingTimestampMillis = null;
      liveForeground.value = null;
      DiagnosticsLog.record('accessibility service disconnected — session dropped', tag: 'usage');
      return;
    }

    // Screen went off: Digital Wellbeing stops counting here, so do we.
    // Attribute the open session as of THIS moment (not whenever the
    // next event happens to come) and clear it.
    if (event.packageName == UlimitSentinel.screenOff) {
      lastScreenOffAt = DateTime.now();
      if (_pendingPackage != null && _pendingTimestampMillis != null) {
        final elapsedSeconds = ((now - _pendingTimestampMillis!) / 1000).floor();
        if (elapsedSeconds > 0 && elapsedSeconds < 6 * 3600 &&
            !isExcludedFromScreenTime(_pendingPackage!)) {
          await _addUsage(_pendingPackage!, _pendingTimestampMillis!, elapsedSeconds);
          DiagnosticsLog.record(
              'screen-off: ${_pendingPackage} session closed (+${elapsedSeconds}s)', tag: 'usage');
        }
      }
      _pendingPackage = null;
      _pendingTimestampMillis = null;
      liveForeground.value = null;
      return;
    }

    if (event.packageName == UlimitSentinel.screenOn) {
      lastScreenOnAt = DateTime.now();
      return;
    }

    // Sentinel from the native feed-surface detector: each hit of a
    // Reels/Shorts/For-You surface is one "feed open" for that
    // platform. These events carry no usage time and must not disturb
    // the usage attribution state below.
    if (event.packageName.startsWith(UlimitSentinel.doomOpenPrefix)) {
      final pkg = event.packageName.substring(UlimitSentinel.doomOpenPrefix.length);
      await _incrementFeedOpen(pkg, now);
      DiagnosticsLog.record(
        'feed surface ejected + counted: ${doomscrollPlatformFor(pkg)?.name ?? pkg}',
        tag: 'feed',
      );
      return;
    }

    var attributedSeconds = 0;
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
        attributedSeconds = elapsedSeconds;
      }
      // A genuine app switch (not the same package re-firing) is what
      // "pickups" counts. Feed-NATIVE doomscroll apps (Reddit etc.) also
      // record an open on entry — their whole app is the doomscroll
      // surface. Section-level apps (Instagram, YouTube…) are counted by
      // the native feed-surface detector via the __doom_open__ sentinel.
      if (_pendingPackage != event.packageName) {
        await _incrementPickup(now);
        if (kDoomscrollPackages.contains(event.packageName) &&
            !isSectionLevelPlatform(event.packageName)) {
          await _incrementFeedOpen(event.packageName, now);
        }
      }
    } else if (_pendingPackage == null) {
      // Very first event of the session: nothing to attribute yet, and
      // no prior app to switch FROM — picking up the phone from the
      // launcher is a pickup, but a cold start into an app is not.
      await _incrementPickup(now);
      if (kDoomscrollPackages.contains(event.packageName) &&
          !isSectionLevelPlatform(event.packageName)) {
        await _incrementFeedOpen(event.packageName, now);
      }
    }

    final previousPackage = _pendingPackage;
    _pendingPackage = event.packageName;
    _pendingTimestampMillis = now;

    final session = LiveForegroundSession(package: event.packageName, sinceMillis: now);
    liveForeground.value = session;
    if (!isExcludedFromScreenTime(event.packageName)) {
      // Snapshot the OS column for this package today NOW — before the
      // session's own time can be committed by a sync cycle. The live
      // ring subtracts (osNow − snapshot) from the pending display so
      // the OS-synced part of the current session is never added twice.
      _snapshotOsColumn(event.packageName, now);
    }
    if (attributedSeconds > 0) {
      DiagnosticsLog.record(
          '${event.packageName} foreground (+${attributedSeconds}s → ${previousPackage ?? '?'})',
          tag: 'usage');
    }
  }

  /// Reads the current `os_foreground_seconds` for [package] today and
  /// attaches it to the live session — unless the session already ended
  /// (another transition or a screen-off landed first).
  Future<void> _snapshotOsColumn(String package, int sinceMillis) async {
    try {
      final day = _truncateToDay(DateTime.fromMillisecondsSinceEpoch(sinceMillis));
      final row = await (_db.select(_db.appUsage)
            ..where((t) => t.packageName.equals(package) & t.day.equals(day)))
          .getSingleOrNull();
      final current = liveForeground.value;
      if (current != null && current.isSameSession(package, sinceMillis)) {
        liveForeground.value = current.withSnapshot(row?.osForegroundSeconds ?? 0);
      }
    } catch (_) {
      // Snapshot is best-effort; the live counter falls back to showing
      // the committed total without pending until the next transition.
    }
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

  /// Bumps today's feed-open count for a doomscroll platform (upsert on
  /// the AppUsage unique key). Called either on app entry for
  /// feed-native platforms, or from the native feed-surface detector
  /// sentinel for section-level ones. Deliberately NOT gated by
  /// isExcludedFromScreenTime — the preset never contains launchers.
  Future<void> _incrementFeedOpen(String package, int atMillis) async {
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
/// counting) and the doomscroll screen's "scrolling" badge. Replays the
/// current value immediately on subscribe.
final liveForegroundProvider = StreamProvider<LiveForegroundSession>((ref) {
  return UsageTracker.liveForegroundStream;
});
