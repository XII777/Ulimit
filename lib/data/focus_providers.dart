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

/// Most recent finished sessions, newest first — Focus history list.
final focusHistoryProvider = StreamProvider<List<FocusSession>>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.focusSessions)
    ..where((t) => t.endedAt.isNotNull())
    ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
    ..limit(100);
  return query.watch();
});

/// One source of truth for focus-session time math. Every surface —
/// the Focus screen, Home's live counter, the Android indicator
/// notification, the enforcement snapshot — derives from these
/// functions against the row's timestamps; nothing increments counters.
class FocusClock {
  static int pausedAccum(FocusSession s) => s.accumulatedPausedSeconds;

  static bool isPaused(FocusSession s) => s.pausedAt != null;

  /// Elapsed RUNNING time in seconds (paused time excluded, frozen
  /// while paused).
  static int elapsedSeconds(FocusSession s, DateTime now) {
    final effectiveEnd = s.pausedAt ?? now;
    final elapsed = effectiveEnd.difference(s.startedAt).inSeconds - s.accumulatedPausedSeconds;
    return elapsed.clamp(0, 1 << 31);
  }

  /// Remaining seconds of the planned duration (frozen while paused).
  static int remainingSeconds(FocusSession s, DateTime now) {
    return (s.plannedSeconds - elapsedSeconds(s, now)).clamp(0, 1 << 31);
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
          blockWebsites: Value(blockInternet),
          invincible: Value(invincible),
        ));
  }

  /// Pauses the running session: timer freezes, restrictions continue.
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

  /// Marks any running session whose planned end has passed as
  /// completed. Called from the evaluation tick so completion happens
  /// even if the timer UI was never open (process death, app swiped
  /// away, phone rebooted) — the timestamp in the row is the authority.
  /// Paused sessions never auto-complete (the timer is frozen).
  Future<void> finalizeIfDue() async {
    final session = await _runningRow();
    if (session == null) return;
    if (session.pausedAt != null) return;
    final plannedEnd = session.startedAt
        .add(Duration(seconds: session.plannedSeconds + session.accumulatedPausedSeconds));
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
      final plannedEnd = session.startedAt
          .add(Duration(seconds: session.plannedSeconds + session.accumulatedPausedSeconds));
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
/// while a session exists — the ValueListenable-style stream drives
/// Home's rolling counter and the Focus ring without rebuilding the
/// rest of either screen.
final focusRemainingProvider = StreamProvider<Duration>((ref) {
  final session = ref.watch(activeFocusSessionProvider).valueOrNull;
  if (session == null) return Stream.value(Duration.zero);
  Duration remaining() => Duration(seconds: FocusClock.remainingSeconds(session, DateTime.now()));

  Future<void> pump(EventSink<Duration> sink) async {
    sink.add(remaining());
    await for (final _ in Stream<void>.periodic(const Duration(seconds: 1))) {
      sink.add(remaining());
    }
  }

  late final StreamController<Duration> controller;
  controller = StreamController<Duration>(
    onListen: () => pump(controller),
    onCancel: () {},
  );
  return controller.stream;
});

/// Live elapsed focus seconds for TODAY (completed sessions today +
/// the running session's live elapsed). Ticks every second only while
/// a session runs; otherwise it's a plain static value.
final liveFocusSecondsTodayProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = startOfDay(DateTime.now());

  Future<int> compute() async {
    final sessions = await (db.select(db.focusSessions)
          ..where((t) => t.startedAt.isBiggerOrEqualValue(start)))
        .get();
    var total = 0;
    final now = DateTime.now();
    for (final s in sessions) {
      if (s.endedAt != null) {
        // Finished today (or finished earlier today after starting
        // today): count actual duration.
        total += FocusClock.elapsedSeconds(
          s,
          s.endedAt ?? now,
        );
      } else {
        total += FocusClock.elapsedSeconds(s, now);
      }
    }
    return total;
  }

  Future<void> pump(EventSink<int> sink) async {
    sink.add(await compute());
    await for (final _ in Stream<void>.periodic(const Duration(seconds: 1))) {
      sink.add(await compute());
    }
  }

  late final StreamController<int> controller;
  controller = StreamController<int>(
    onListen: () => pump(controller),
    onCancel: () {},
  );
  // Re-run when the session row changes (start/end/complete).
  ref.listen(activeFocusSessionProvider, (_, __) {
    Future.microtask(() async {
      if (!controller.isClosed) controller.add(await compute());
    });
  });
  return controller.stream;
});
