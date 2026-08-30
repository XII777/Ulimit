import 'dart:async';

import 'package:drift/drift.dart';
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

  /// Elapsed RUNNING time in seconds (paused time excluded, frozen
  /// while paused).
  static int elapsedSeconds(FocusSession s, DateTime now) {
    final effectiveEnd = s.pausedAt ?? now;
    final elapsed =
        effectiveEnd.difference(s.startedAt).inSeconds - s.accumulatedPausedSeconds;
    return elapsed < 0 ? 0 : elapsed;
  }

  /// Remaining seconds of the planned duration (frozen while paused).
  static int remainingSeconds(FocusSession s, DateTime now) {
    final remaining = s.plannedSeconds - elapsedSeconds(s, now);
    return remaining < 0 ? 0 : remaining;
  }

  /// When the session would naturally complete, accounting for pauses.
  static DateTime plannedEnd(FocusSession s) =>
      s.startedAt.add(Duration(seconds: s.plannedSeconds + s.accumulatedPausedSeconds));
}

class FocusController {
  FocusController(this._db);

  final AppDatabase _db;

  Future<void> startSession({
    required String label,
    required Duration duration,
    required List<String> blockedPackages,
    bool pauseNotifications = true,
    bool blockInternet = false,
    bool blockWebsites = false,
    bool invincible = false,
  }) async {
    // Only one session can run at a time — close any stale open row
    // (e.g. after a crash) before starting the new one.
    await _finalizeStaleSessions();

    await _db.into(_db.focusSessions).insert(FocusSessionsCompanion.insert(
          label: label,
          startedAt: DateTime.now(),
          plannedSeconds: duration.inSeconds,
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
  /// row is the authority. Paused sessions never auto-complete.
  Future<void> finalizeIfDue() async {
    final session = await _runningRow();
    if (session == null) return;
    if (session.pausedAt != null) return;
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

Stream<Duration> _remainingStream(FocusSession session) async* {
  Duration remaining() =>
      Duration(seconds: FocusClock.remainingSeconds(session, DateTime.now()));
  yield remaining();
  await for (final _ in Stream<void>.periodic(const Duration(seconds: 1))) {
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

  Future<int> compute() async {
    try {
      final sessions = await (db.select(db.focusSessions)
            ..where((t) => t.startedAt.isBiggerOrEqualValue(start)))
          .get();
      final now = DateTime.now();
      var total = 0;
      for (final s in sessions) {
        total += FocusClock.elapsedSeconds(s, s.endedAt ?? now);
      }
      return total;
    } catch (_) {
      return 0; // a broken DB must never blank the dashboard
    }
  }

  // While a session runs: tick every second. Without one: a static
  // value that still refreshes on session changes (the watch above
  // rebuilds this provider on start/end).
  if (session == null) {
    return Stream.fromFuture(compute());
  }
  return _liveFocusStream(compute);
});

Stream<int> _liveFocusStream(Future<int> Function() compute) async* {
  yield await compute();
  await for (final _ in Stream<void>.periodic(const Duration(seconds: 1))) {
    yield await compute();
  }
}
