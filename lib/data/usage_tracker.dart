import 'dart:async';
import 'package:drift/drift.dart';
import '../core/native/usage_events_channel.dart';
import 'db/app_database.dart';

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
  UsageTracker(this._db);

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

    if (_pendingPackage != null && _pendingTimestampMillis != null) {
      final elapsedSeconds = ((now - _pendingTimestampMillis!) / 1000).round();
      if (elapsedSeconds > 0 && elapsedSeconds < 6 * 3600) {
        // Discard >6h gaps — almost certainly a phone-asleep period the
        // OS didn't cleanly signal, not real foreground time.
        await _addUsage(_pendingPackage!, _pendingTimestampMillis!, elapsedSeconds);
      }
      // A genuine app switch (not the same package re-firing) is what
      // "pickups" counts.
      if (_pendingPackage != event.packageName) {
        await _incrementPickup(now);
      }
    } else {
      await _incrementPickup(now);
    }

    _pendingPackage = event.packageName;
    _pendingTimestampMillis = now;
  }

  Future<void> _addUsage(String package, int atMillis, int seconds) async {
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
      [package, day.millisecondsSinceEpoch, seconds],
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

  DateTime _truncateToDay(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
}
