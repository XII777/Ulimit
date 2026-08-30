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
    ..limit(30);
  return query.watch();
});

class FocusController {
  FocusController(this._ref);

  final Ref _ref;

  AppDatabase get _db => _ref.read(databaseProvider);

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
  Future<void> finalizeIfDue() async {
    final session = await _runningRow();
    if (session == null) return;
    final plannedEnd = session.startedAt.add(Duration(seconds: session.plannedSeconds));
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
      final plannedEnd = session.startedAt.add(Duration(seconds: session.plannedSeconds));
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
  final controller = FocusController(ref);
  // Finalize due sessions on every evaluation tick — this is what makes
  // a session "complete itself" overnight or after process death
  // without any alarm infrastructure.
  ref.listen(evaluationTickProvider, (_, __) => controller.finalizeIfDue());
  return controller;
});

/// Remaining time of the running session (zero when none/finished).
final focusRemainingProvider = StreamProvider<Duration>((ref) {
  final session = ref.watch(activeFocusSessionProvider).valueOrNull;
  if (session == null) return Stream.value(Duration.zero);
  final plannedEnd = session.startedAt.add(Duration(seconds: session.plannedSeconds));

  Duration remaining() => plannedEnd.difference(DateTime.now());

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
