import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/diagnostics/diagnostics_log.dart';
import 'db/app_database.dart';
import 'doomscroll_apps.dart';
import 'providers.dart';
import 'usage_tracker.dart';

// ---------------------------------------------------------------------------
// Rules (per-platform config)
// ---------------------------------------------------------------------------

class DoomscrollRule {
  const DoomscrollRule({
    required this.packageName,
    required this.enabled,
    required this.dailyOpenLimit,
  });

  final String packageName;
  final bool enabled;
  final int dailyOpenLimit; // 0 = block outright
}

/// All configured doomscroll rules.
final doomscrollRulesProvider = StreamProvider<List<DoomscrollRule>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.doomscrollRules)).watch().map(
        (rows) => [
          for (final r in rows)
            DoomscrollRule(
              packageName: r.packageName,
              enabled: r.enabled,
              dailyOpenLimit: r.dailyOpenLimit,
            ),
        ],
      );
});

/// The union of every enabled doomscroll package — the preset the focus
/// screen's one-switch control adds to a session's blocked list, and the
/// platforms shown in the analytics.
final activeDoomscrollPackagesProvider = Provider<Set<String>>((ref) {
  final rules = ref.watch(doomscrollRulesProvider).valueOrNull;
  if (rules == null) return const {};
  return {for (final r in rules) if (r.enabled) r.packageName};
});

extension DoomscrollActions on AppDatabase {
  Future<void> setDoomscrollPlatform({
    required String packageName,
    required bool enabled,
    required int dailyOpenLimit,
  }) async {
    await into(doomscrollRules).insertOnConflictUpdate(
      DoomscrollRulesCompanion.insert(
        packageName: packageName,
        enabled: Value(enabled),
        dailyOpenLimit: Value(dailyOpenLimit),
      ),
    );
    DiagnosticsLog.record(
      'doomscroll rule saved: ${doomscrollPlatformFor(packageName)?.name ?? packageName} → '
      '${enabled ? (dailyOpenLimit == 0 ? "feed blocked outright" : "$dailyOpenLimit opens/day") : "off"}',
      tag: 'rules',
    );
  }

  Future<void> setDoomscrollEnabled(String packageName, bool enabled) async {
    await (update(doomscrollRules)..where((t) => t.packageName.equals(packageName)))
        .write(DoomscrollRulesCompanion(enabled: Value(enabled)));
  }

  Future<void> removeDoomscrollPlatform(String packageName) async {
    await (delete(doomscrollRules)..where((t) => t.packageName.equals(packageName))).go();
    DiagnosticsLog.record(
      'doomscroll rule removed: ${doomscrollPlatformFor(packageName)?.name ?? packageName}',
      tag: 'rules',
    );
  }
}

// ---------------------------------------------------------------------------
// Live counts (today)
// ---------------------------------------------------------------------------

/// Today's open counts for ALL doomscroll apps, keyed by package. The
/// watcher lives in UsageTracker writes; a live session in a feed app
/// adds its pending opens when the next transition arrives.
final doomscrollTodayCountsProvider = StreamProvider<Map<String, int>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = startOfDay(DateTime.now());
  final packages = kDoomscrollPackages;

  final query = db.select(db.appUsage)
    ..where((t) => t.day.equals(today) & t.packageName.isIn(packages));

  return query.watch().map(
        (rows) => {for (final r in rows) r.packageName: r.openCount},
      );
});

/// Sum of every doomscroll open today — the headline analytics number.
final doomscrollTodayTotalProvider = Provider<int>((ref) {
  final counts = ref.watch(doomscrollTodayCountsProvider).valueOrNull;
  if (counts == null) return 0;
  return counts.values.fold(0, (a, b) => a + b);
});

/// Seconds spent in doomscroll apps today (feeds the "time in feeds"
/// analytics card).
final doomscrollTodaySecondsProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final today = startOfDay(DateTime.now());

  final query = db.select(db.appUsage)
    ..where((t) => t.day.equals(today) & t.packageName.isIn(kDoomscrollPackages));

  return query.watch().map(
        (rows) => rows.fold(0, (sum, r) => sum + r.foregroundSeconds),
      );
});

/// Whether the doomscroll counter is currently going up: the live
/// foreground app is a doomscroll platform. Drives the "scrolling"
/// badge on the analytics page and the notification chip.
final doomscrollLiveActiveProvider = Provider<bool>((ref) {
  final foreground = ref.watch(liveForegroundProvider).valueOrNull;
  if (foreground == null) return false;
  return doomscrollPlatformFor(foreground.package) != null;
});

// ---------------------------------------------------------------------------
// Weekly analytics
// ---------------------------------------------------------------------------

/// One day of doomscroll analytics.
class DoomscrollDay {
  const DoomscrollDay({
    required this.day,
    required this.opens,
    required this.seconds,
  });

  final DateTime day;
  final int opens;
  final int seconds;
}

/// Last 7 days of aggregate doomscroll opens (oldest → newest), one
/// entry per day. Pure DB streaming — no per-day fan-out.
final doomscrollWeeklyOpensProvider = StreamProvider<List<DoomscrollDay>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 6));

  final query = db.select(db.appUsage)
    ..where((t) =>
        t.day.isBiggerOrEqualValue(start) & t.packageName.isIn(kDoomscrollPackages));

  return query.watch().map((rows) {
    final opensByDay = <DateTime, int>{};
    final secondsByDay = <DateTime, int>{};
    for (var i = 0; i <= 6; i++) {
      final day = start.add(Duration(days: i));
      opensByDay[day] = 0;
      secondsByDay[day] = 0;
    }
    for (final r in rows) {
      final d = startOfDay(r.day.toLocal());
      opensByDay[d] = (opensByDay[d] ?? 0) + r.openCount;
      secondsByDay[d] = (secondsByDay[d] ?? 0) + r.foregroundSeconds;
    }
    return [
      for (var i = 0; i <= 6; i++)
        DoomscrollDay(
          day: start.add(Duration(days: i)),
          opens: opensByDay[start.add(Duration(days: i))]!,
          seconds: secondsByDay[start.add(Duration(days: i))]!,
        ),
    ];
  });
});

/// Per-platform weekly opens for the leaderboard — one stream instead of
/// a provider per platform (17 platforms × 2 queries each would be 34
/// live queries on one screen; this is 1).
final doomscrollWeeklyByPlatformProvider =
    StreamProvider<Map<String, List<int>>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 6));

  final query = db.select(db.appUsage)
    ..where((t) =>
        t.day.isBiggerOrEqualValue(start) & t.packageName.isIn(kDoomscrollPackages));

  return query.watch().map((rows) {
    final out = <String, List<int>>{};
    for (final r in rows) {
      final d = startOfDay(r.day.toLocal());
      final index = d.difference(start).inDays.clamp(0, 6);
      final list = out.putIfAbsent(r.packageName, () => List.filled(7, 0));
      list[index] += r.openCount;
    }
    return out;
  });
});

/// Last week's total opens (days 13→7 ago) — the weekly delta baseline.
final doomscrollPreviousWeekTotalProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = startOfDay(DateTime.now()).subtract(const Duration(days: 13));
  final end = startOfDay(DateTime.now()).subtract(const Duration(days: 6));

  final query = db.select(db.appUsage)
    ..where((t) =>
        t.day.isBiggerOrEqualValue(start) &
        t.day.isSmallerThanValue(end) &
        t.packageName.isIn(kDoomscrollPackages));

  return query.watch().map(
        (rows) => rows.fold(0, (sum, r) => sum + r.openCount),
      );
});
