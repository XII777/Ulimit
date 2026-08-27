import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'db/app_database.dart';

/// Single DB instance for the app's lifetime. `keepAlive` so switching
/// tabs doesn't tear down and reopen the SQLite connection — that
/// reopen cost is exactly the kind of jank a "don't make it lag"
/// requirement is about.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Today's total foreground time across all tracked apps, as a live
/// stream — Drift's .watch() pushes updates only when the underlying
/// rows change, so the ring on Home updates in real time without
/// polling.
final todayScreenTimeProvider = StreamProvider<Duration>((ref) {
  final db = ref.watch(databaseProvider);
  final startOfDay = DateTime.now().let((n) => DateTime(n.year, n.month, n.day));

  final query = db.select(db.appUsage)
    ..where((t) => t.day.equals(startOfDay));

  return query.watch().map(
        (rows) => Duration(
          seconds: rows.fold(0, (sum, r) => sum + r.foregroundSeconds),
        ),
      );
});

// Small extension so the provider above reads top-to-bottom instead of
// nesting a let-less temp variable — purely a readability choice.
extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
