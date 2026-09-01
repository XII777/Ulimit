import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'db/app_database.dart';
import 'providers.dart';

/// The running session, if any: the newest row with `endedAt` still
/// null. Correctness after process death comes from the DB row, not
/// from any in-memory timer — if the app is killed mid-session the row
/// is still here when the app relaunches.
final activeFocusSessionProvider = StreamProvider<FocusSession?>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.focusSessions)
    ..where((t) => t.endedAt.isNull())
    ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
    ..limit(1);
  return query.watchSingleOrNull();
});

/// All sessions, newest first — Focus history list.
final focusHistoryProvider = StreamProvider<List<FocusSession>>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.focusSessions)
    ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
    ..limit(100);
  return query.watch();
});

/// One source of truth for focus-session time math. Every surface —
/// the Focus screen, Home's live counter, the Android indicator
/// notification, the enforcement snapshot — derives from these
/// functions against the row's timestamps; nothing increments counters.
class FocusClock {
  static bool isPaused(FocusSession s) => s.pausedAt != null;

  /// True for untimed sessions ("until I turn it off", plannedSeconds = -1).
  static bool isUntimed(FocusSession s) => s.plannedSeconds < 0;

  /// Elapsed RUNNING time in seconds (paused time excluded, frozen
  /// while paused).
  static int elapsedSeconds(FocusSession s, DateTime now) {
    final effectiveEnd = s.pausedAt ?? now;
    final elapsed =
        effectiveEnd.difference(s.startedAt).inSeconds - s.accumulatedPausedSeconds;
    return elapsed < 0 ? 0 : elapsed;
  }

  /// Remaining seconds of the planned duration (frozen while paused).
  /// Untimed sessions always report the intent to keep running: null.
  static int? remainingSeconds(FocusSession s, DateTime now) {
    if (isUntimed(s)) return null;
    final remaining = s.plannedSeconds - elapsedSeconds(s, now);
    return remaining < 0 ? 0 : remaining;
  }

  /// When the session would naturally complete, accounting for pauses.
  /// Untimed sessions report a far-future instant — the engine's
  /// "until" fields need a concrete DateTime and this is that: the
  /// session is effectively indefinite.
  static DateTime plannedEnd(FocusSession s) {
    if (isUntimed(s)) return s.startedAt.add(const Duration(days: 3650));
    return s.startedAt.add(Duration(seconds: s.plannedSeconds + s.accumulatedPausedSeconds));
  }
}

class FocusController {
  FocusController(this._db);

  final AppDatabase _db;

  Future<void> startSession({
    required String label,
    Duration? duration,
    required List<String> blockedPackages,
    bool pauseNotifications = true,
    bool blockInternet = false,
    bool blockWebsites = false,
    bool invincible = false,
  }) async {
    // Only one session can run at a time — close any stale open row
    // (e.g. after a crash) before starting the new one.
    await _finalizeStaleSessions();

    // A null duration means "until I turn it off" — an untimed session.
    // Sentinel -1 marks it so every reader (timer, engine, history)
    // knows it never auto-completes.
    final plannedSeconds = duration?.inSeconds ?? -1;

    await _db.into(_db.focusSessions).insert(FocusSessionsCompanion.insert(
          label: label,
          startedAt: DateTime.now(),
          plannedSeconds: plannedSeconds,
          blockedPackages: Value(blockedPackages),
          pauseNotifications: Value(pauseNotifications),
          blockInternet: Value(blockInternet),
          blockWebsites: Value(blockWebsites),
          invincible: Value(invincible),
        ));
  }

  /// Pauses the running session: the timer freezes but the session and
  /// its restrictions continue.
  Future<void> pause() async {
    final session = await _runningRow();
    if (session == null || session.pausedAt != null) return;
    await (_db.update(_db.focusSessions)..where((t) => t.id.equals(session.id))).write(
      FocusSessionsCompanion(pausedAt: Value(DateTime.now())),
    );
  }

  /// Resumes a paused session: the accumulated pause time grows so the
  /// timer continues exactly where it froze (no drift).
  Future<void> resume() async {
    final session = await _runningRow();
    if (session == null || session.pausedAt == null) return;
    final pausedFor = DateTime.now().difference(session.pausedAt!).inSeconds;
    await (_db.update(_db.focusSessions)..where((t) => t.id.equals(session.id))).write(
      FocusSessionsCompanion(
        pausedAt: const Value(null),
        accumulatedPausedSeconds: Value(session.accumulatedPausedSeconds + pausedFor),
      ),
    );
  }

  /// Ends the running session early. `completed` stays false so history
  /// distinguishes an abandoned session from a finished one.
  Future<void> endEarly() async {
    final session = await _runningRow();
    if (session == null) return;
    await (_db.update(_db.focusSessions)..where((t) => t.id.equals(session.id))).write(
      FocusSessionsCompanion(endedAt: Value(DateTime.now()), completed: const Value(false)),
    );
  }

  /// Marks any running (and not paused) session whose planned end has
  /// passed as completed. Called from the evaluation tick so completion
  /// happens even if the timer UI was never open — the timestamp in the
  /// row is the authority. Paused sessions never auto-complete, and
  /// untimed sessions ("until I turn it off") never auto-complete at all.
  Future<void> finalizeIfDue() async {
    final session = await _runningRow();
    if (session == null) return;
    if (session.pausedAt != null) return;
    if (FocusClock.isUntimed(session)) return;
    final plannedEnd = FocusClock.plannedEnd(session);
    if (DateTime.now().isBefore(plannedEnd)) return;
    await (_db.update(_db.focusSessions)..where((t) => t.id.equals(session.id))).write(
      FocusSessionsCompanion(endedAt: Value(plannedEnd), completed: const Value(true)),
    );
  }

  Future<FocusSession?> _runningRow() async {
    return await (_db.select(_db.focusSessions)
          ..where((t) => t.endedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> _finalizeStaleSessions() async {
    final running = await (_db.select(_db.focusSessions)..where((t) => t.endedAt.isNull())).get();
    if (running.isEmpty) return;
    final now = DateTime.now();
    for (final session in running) {
      if (FocusClock.isUntimed(session)) continue;
      final plannedEnd = FocusClock.plannedEnd(session);
      final ended = now.isBefore(plannedEnd) ? now : plannedEnd;
      await (_db.update(_db.focusSessions)..where((t) => t.id.equals(session.id))).write(
        FocusSessionsCompanion(endedAt: Value(ended), completed: Value(now.isAfter(plannedEnd))),
      );
    }
  }

  Future<void> deleteSession(int id) async {
    await (_db.delete(_db.focusSessions)..where((t) => t.id.equals(id))).go();
  }
}

final focusControllerProvider = Provider<FocusController>((ref) {
  final controller = FocusController(ref.watch(databaseProvider));
  // Finalize due sessions on every evaluation tick — this is what makes
  // a session "complete itself" overnight or after process death
  // without any alarm infrastructure.
  ref.listen(evaluationTickProvider, (_, __) => controller.finalizeIfDue());
  return controller;
});

/// Remaining time of the running session, ticking every second ONLY
/// while a session exists. async* generators restart cleanly on every
/// subscription — no hand-managed StreamController lifecycles.
final focusRemainingProvider = StreamProvider<Duration>((ref) {
  final session = ref.watch(activeFocusSessionProvider).valueOrNull;
  if (session == null) return Stream.value(Duration.zero);
  return _remainingStream(session);
});

/// Ticks at 1s in the foreground, 5s when backgrounded. The ticker
/// itself is cheap (a Timer + arithmetic), but a foreground session
/// running while the keep-alive tabs churn would otherwise waste a full
/// rebuild per second — the adaptive cadence keeps the drain invisible.
Stream<void> _tickStream() async* {
  var backgrounded = false;
  final observer = _AppLifecycleObserver((state) {
    backgrounded = state != AppLifecycleState.resumed;
  });
  WidgetsBinding.instance.addObserver(observer);
  try {
    while (true) {
      yield null;
      await Future<void>.delayed(
          backgrounded ? const Duration(seconds: 5) : const Duration(seconds: 1));
    }
  } finally {
    WidgetsBinding.instance.removeObserver(observer);
  }
}

Stream<Duration> _remainingStream(FocusSession session) async* {
  Duration remaining() {
    final seconds = FocusClock.remainingSeconds(session, DateTime.now());
    return Duration(seconds: seconds ?? 0);
  }

  yield remaining();
  await for (final _ in _tickStream()) {
    yield remaining();
  }
}

/// Live elapsed focus seconds for TODAY (completed sessions today +
/// the running session's live elapsed). Ticks every second only while
/// a session runs; otherwise it's a plain static value.
final liveFocusSecondsTodayProvider = StreamProvider<int>((ref) {
  final session = ref.watch(activeFocusSessionProvider).valueOrNull;
  final db = ref.watch(databaseProvider);
  final start = startOfDay(DateTime.now());

  // One-shot query: total focus time for all COMPLETED/aged sessions
  // today. Runs ONCE per session change, not once per second — the
  // per-second part below is pure arithmetic on the running row.
  Future<int> totalFromDb() async {
    try {
      final sessions = await (db.select(db.focusSessions)
            ..where((t) => t.startedAt.isBiggerOrEqualValue(start)))
          .get();
      var total = 0;
      final now = DateTime.now();
      for (final s in sessions) {
        if (FocusClock.isUntimed(s) && s.endedAt == null) continue;
        total += FocusClock.elapsedSeconds(s, s.endedAt ?? now);
      }
      return total;
    } catch (_) {
      return 0; // a broken DB must never blank the dashboard
    }
  }

  // While a session runs: query the settled total ONCE, then tick with
  // pure arithmetic (row elapsed + wall clock) instead of a DB query
  // per second. Without a session: a static value that still refreshes
  // on session changes (the watch above rebuilds on start/end).
  if (session == null) {
    return Stream.fromFuture(totalFromDb());
  }
  return _liveFocusStream(session, totalFromDb);
});

/// Live focus ticker: settled-total (one DB read) + running-session
/// elapsed time computed per tick. The DB is never touched per second.
Stream<int> _liveFocusStream(FocusSession session, Future<int> Function() settledTotal) async* {
  final settled = await settledTotal();
  // Subtract the running row's *settled* contribution so it's not
  // double-counted: elapsedSeconds(row, now) is computed fresh below.
  final rowElapsedAtQuery = FocusClock.elapsedSeconds(session, DateTime.now());
  final base = (settled - rowElapsedAtQuery).clamp(0, 1 << 30);
  yield base + rowElapsedAtQuery;
  await for (final _ in _tickStream()) {
    yield base + FocusClock.elapsedSeconds(session, DateTime.now());
  }
}

/// Lifecycle observer shim so tickers can adapt their cadence to the
/// app's visibility without being WidgetsBindingObservers themselves.
class _AppLifecycleObserver extends WidgetsBindingObserver {
  _AppLifecycleObserver(this._onChange);
  final void Function(AppLifecycleState) _onChange;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _onChange(state);
}
