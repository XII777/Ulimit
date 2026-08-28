import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'db/app_database.dart';
import 'db/tables.dart';

/// Single DB instance for the app's lifetime. `keepAlive` so switching
/// tabs doesn't tear down and reopen the SQLite connection — that
/// reopen cost is exactly the kind of jank a "don't make it lag"
/// requirement is about.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

/// Today's total foreground time across all tracked apps, as a live
/// stream — Drift's .watch() pushes updates only when the underlying
/// rows change, so the ring on Home updates in real time without
/// polling.
final todayScreenTimeProvider = StreamProvider<Duration>((ref) {
  final db = ref.watch(databaseProvider);
  final startOfDay = _startOfDay(DateTime.now());

  final query = db.select(db.appUsage)..where((t) => t.day.equals(startOfDay));

  return query.watch().map(
        (rows) => Duration(seconds: rows.fold(0, (sum, r) => sum + r.foregroundSeconds)),
      );
});

/// Last 7 days of total foreground time, oldest first — feeds Home's
/// weekly trend chart. One GROUP-BY-shaped query instead of 7 separate
/// day lookups.
final weeklyScreenTimeProvider = StreamProvider<List<Duration>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = _startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 6));

  final query = db.select(db.appUsage)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) => _bucketByDay(rows.map((r) => (r.day, r.foregroundSeconds)), start));
});

/// The 7 days before [weeklyScreenTimeProvider]'s window — used only to
/// compute the "vs last week" delta shown next to the weekly chart, so
/// that delta is a real comparison rather than a made-up percentage.
final previousWeekScreenTimeAvgProvider = StreamProvider<Duration>((ref) {
  final db = ref.watch(databaseProvider);
  final today = _startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 13));
  final end = today.subtract(const Duration(days: 6));

  final query = db.select(db.appUsage)
    ..where((t) => t.day.isBiggerOrEqualValue(start) & t.day.isSmallerThanValue(end));

  return query.watch().map((rows) {
    final total = rows.fold(0, (sum, r) => sum + r.foregroundSeconds);
    return Duration(seconds: total ~/ 7);
  });
});

/// Last 7 days of completed-focus-session time, oldest first. Falls
/// back to `plannedSeconds` for a session with no `endedAt` yet (in
/// progress) so an active session doesn't read as zero minutes.
final weeklyFocusTimeProvider = StreamProvider<List<Duration>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = _startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 6));

  final query = db.select(db.focusSessions)
    ..where((t) => t.completed.equals(true) & t.startedAt.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final entries = rows.map((r) {
      final seconds = r.endedAt != null ? r.endedAt!.difference(r.startedAt).inSeconds : r.plannedSeconds;
      return (r.startedAt, seconds);
    });
    return _bucketByDay(entries, start);
  });
});

/// Previous-week counterpart to [weeklyFocusTimeProvider], for its delta.
final previousWeekFocusTimeAvgProvider = StreamProvider<Duration>((ref) {
  final db = ref.watch(databaseProvider);
  final today = _startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 13));
  final end = today.subtract(const Duration(days: 6));

  final query = db.select(db.focusSessions)
    ..where((t) =>
        t.completed.equals(true) & t.startedAt.isBiggerOrEqualValue(start) & t.startedAt.isSmallerThanValue(end));

  return query.watch().map((rows) {
    final total = rows.fold<int>(0, (sum, r) {
      final seconds = r.endedAt != null ? r.endedAt!.difference(r.startedAt).inSeconds : r.plannedSeconds;
      return sum + seconds;
    });
    return Duration(seconds: total ~/ 7);
  });
});

/// Count of focus sessions completed so far today — feeds both Home's
/// "N sessions" pill and Focus's "today's sessions" dot row.
final todaysCompletedSessionsProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _startOfDay(DateTime.now());
  final end = start.add(const Duration(days: 1));

  final query = db.select(db.focusSessions)
    ..where((t) =>
        t.completed.equals(true) & t.startedAt.isBiggerOrEqualValue(start) & t.startedAt.isSmallerThanValue(end));

  return query.watch().map((rows) => rows.length);
});

/// Turns a stream of (day, seconds) rows into a fixed 7-slot list
/// starting at [start], zero-filling any day with no rows. Shared by
/// both weekly providers above so "bucket into a 7-day window" is
/// implemented once.
List<Duration> _bucketByDay(Iterable<(DateTime, int)> entries, DateTime start) {
  final byDay = <DateTime, int>{for (var i = 0; i <= 6; i++) start.add(Duration(days: i)): 0};
  for (final (day, seconds) in entries) {
    final d = _startOfDay(day);
    byDay[d] = (byDay[d] ?? 0) + seconds;
  }
  final orderedDays = byDay.keys.toList()..sort();
  return [for (final d in orderedDays) Duration(seconds: byDay[d]!)];
}

/// One restriction group with today's live usage joined in. Replaces
/// the Limits screen's hardcoded group list — `packageNames` drives the
/// icon row, `usedSeconds`/`limitSeconds` drive the bar and its color.
class RestrictionGroupView {
  const RestrictionGroupView({
    required this.name,
    required this.usedSeconds,
    required this.limitSeconds,
    required this.invincible,
    required this.packageNames,
  });

  final String name;
  final int usedSeconds;
  final int limitSeconds;
  final bool invincible;
  final List<String> packageNames;
}

final restrictionGroupsProvider = StreamProvider<List<RestrictionGroupView>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = _startOfDay(DateTime.now());

  // One joined query rather than combining separate group/usage streams
  // — keeps this a single reactive source instead of hand-rolled stream
  // combination.
  final query = db.customSelect(
    '''
    SELECT rg.id AS group_id, rg.name AS name, rg.daily_limit_seconds AS daily_limit_seconds,
           rg.invincible AS invincible, rga.package_name AS package_name,
           COALESCE(usage.foreground_seconds, 0) AS pkg_seconds
    FROM restriction_groups rg
    LEFT JOIN restriction_group_apps rga ON rga.group_id = rg.id
    LEFT JOIN app_usage usage ON usage.package_name = rga.package_name AND usage.day = ?
    ORDER BY rg.id
    ''',
    variables: [Variable.withDateTime(today)],
    readsFrom: {db.restrictionGroups, db.restrictionGroupApps, db.appUsage},
  );

  return query.watch().map((rows) {
    final byGroup = <int, _MutableGroup>{};
    final order = <int>[];

    for (final row in rows) {
      final id = row.read<int>('group_id');
      final group = byGroup.putIfAbsent(id, () {
        order.add(id);
        return _MutableGroup(
          name: row.read<String>('name'),
          limitSeconds: row.read<int>('daily_limit_seconds'),
          invincible: row.read<bool>('invincible'),
        );
      });

      final pkg = row.readNullable<String>('package_name');
      if (pkg != null) {
        group.packageNames.add(pkg);
        group.usedSeconds += row.read<int>('pkg_seconds');
      }
    }

    return [for (final id in order) byGroup[id]!.toView()];
  });
});

class _MutableGroup {
  _MutableGroup({required this.name, required this.limitSeconds, required this.invincible});
  final String name;
  final int limitSeconds;
  final bool invincible;
  int usedSeconds = 0;
  final List<String> packageNames = [];

  RestrictionGroupView toView() => RestrictionGroupView(
        name: name,
        usedSeconds: usedSeconds,
        limitSeconds: limitSeconds,
        invincible: invincible,
        packageNames: packageNames,
      );
}

/// Count of enabled entries in [BlockedApps] — feeds the "App Blocking"
/// control tile's subtitle on Home.
final blockedAppsCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.blockedApps)..where((t) => t.enabled.equals(true));
  return query.watch().map((rows) => rows.length);
});

/// The single [BedtimeSchedule] row (singleton, like [Profile]) — null
/// until the first toggle write creates it.
final bedtimeScheduleProvider = StreamProvider<BedtimeScheduleData?>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.bedtimeSchedule)..limit(1);
  return query.watch().map((rows) => rows.isEmpty ? null : rows.first);
});

extension BedtimeScheduleActions on AppDatabase {
  Future<void> _ensureBedtimeRow() async {
    final existing = await (select(bedtimeSchedule)..limit(1)).getSingleOrNull();
    if (existing == null) {
      await into(bedtimeSchedule).insert(
        BedtimeScheduleCompanion.insert(startTime: '22:30', endTime: '06:30'),
      );
    }
  }

  Future<void> setDndEnabled(bool value) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(dndEnabled: Value(value)));
  }

  Future<void> setPauseApps(bool value) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(pauseApps: Value(value)));
  }

  Future<void> setGrayscale(bool value) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(grayscale: Value(value)));
  }
}
