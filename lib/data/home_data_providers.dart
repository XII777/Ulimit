import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';

/// Weekly/delta computation for the Home dashboard. Kept separate from
/// providers.dart so the Home screen imports a small, purpose-shaped
/// surface instead of the whole data layer.

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _daysAgo(int n) => _startOfDay(DateTime.now().subtract(Duration(days: n)));

/// Last 7 days of total screen time, oldest→newest, in hours — feeds
/// the weekly trend chart directly.
final weeklyScreenTimeHoursProvider = StreamProvider<List<double>>((ref) {
  return ref.watch(weeklyScreenTimeProvider.stream).map(
        (days) => [for (final d in days) d.inSeconds / 3600.0],
      );
});

/// Daily focus-session totals for the last 7 days, oldest→newest, in
/// hours — mirrors weeklyScreenTimeHoursProvider's shape so both feed
/// the same chart widgets consistently.
final weeklyFocusHoursByDayProvider = StreamProvider<List<double>>((ref) {
  return ref.watch(weeklyFocusTimeProvider.stream).map(
        (days) => [for (final d in days) d.inSeconds / 3600.0],
      );
});

/// Total completed focus-session time this week, in seconds.
final weeklyFocusSecondsProvider = StreamProvider<int>((ref) {
  return ref.watch(weeklyFocusTimeProvider.stream).map(
        (days) => days.fold(0, (sum, d) => sum + d.inSeconds),
      );
});

/// Prior-week (days 13→7 ago) total screen time, in hours — the
/// comparison baseline for the "vs last week" delta shown on Home.
/// A genuine second query rather than deriving it from the 7-day
/// array, since that array only covers the current week.
final previousWeekScreenTimeHoursProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(13);
  final end = _daysAgo(7);

  final query = db.select(db.appUsage)
    ..where((t) => t.day.isBiggerOrEqualValue(start) & t.day.isSmallerThanValue(end));

  return query.watch().map((rows) {
    final byDay = <DateTime, int>{};
    for (final r in rows) {
      // Drift reads DateTimeColumn as UTC; convert to local before
      // bucketing (see bucketByDay's note) so prior-week deltas match
      // the user's calendar days.
      byDay.update(startOfDay(r.day.toLocal()), (v) => v + r.foregroundSeconds,
          ifAbsent: () => r.foregroundSeconds);
    }
    return List.generate(7, (i) {
      final day = _daysAgo(13 - i);
      return (byDay[day] ?? 0) / 3600.0;
    });
  });
});

/// Prior-week completed focus-session seconds — comparison baseline
/// for the Focus time mini-card delta.
final previousWeekFocusSecondsProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(13);
  final end = _daysAgo(7);

  final query = db.select(db.focusSessions)
    ..where((t) =>
        t.startedAt.isBiggerOrEqualValue(start) &
        t.startedAt.isSmallerThanValue(end) &
        t.completed.equals(true));

  return query.watch().map((rows) => rows.fold<int>(0, (sum, s) {
        if (s.endedAt == null) return sum;
        return sum + s.endedAt!.difference(s.startedAt).inSeconds;
      }));
});

/// Prior-week pickup counts — comparison baseline for the Pickups
/// mini-card delta.
final previousWeekPickupsProvider = StreamProvider<List<int>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(13);
  final end = _daysAgo(7);

  final query = db.select(db.pickupsLog)
    ..where((t) => t.day.isBiggerOrEqualValue(start) & t.day.isSmallerThanValue(end));

  return query.watch().map((rows) {
    final byDay = {for (final r in rows) r.day: r.count};
    return List.generate(7, (i) {
      final day = _daysAgo(13 - i);
      return byDay[day] ?? 0;
    });
  });
});

/// A single "up X% / down X%" result with the semantic direction
/// already resolved. Direction is carried by the arrow glyph and
/// wording — never color, per the design system.
class TrendDelta {
  const TrendDelta({required this.percent, required this.isPositive, required this.hasData});
  final double percent; // always positive magnitude; sign shown via arrow
  final bool isPositive;
  final bool hasData;

  static const none = TrendDelta(percent: 0, isPositive: true, hasData: false);
}

TrendDelta _computeDelta({
  required double current,
  required double previous,
  required bool lowerIsBetter,
}) {
  if (previous <= 0) return TrendDelta.none;
  final change = (current - previous) / previous;
  final magnitude = change.abs() * 100;
  final wentUp = change > 0;
  final isPositive = lowerIsBetter ? !wentUp : wentUp;
  return TrendDelta(percent: magnitude, isPositive: isPositive, hasData: true);
}

final screenTimeDeltaProvider = Provider<TrendDelta>((ref) {
  final current = ref.watch(weeklyScreenTimeHoursProvider).valueOrNull;
  final previous = ref.watch(previousWeekScreenTimeHoursProvider).valueOrNull;
  if (current == null || previous == null) return TrendDelta.none;
  final curAvg = current.isEmpty ? 0.0 : current.reduce((a, b) => a + b) / current.length;
  final prevAvg = previous.isEmpty ? 0.0 : previous.reduce((a, b) => a + b) / previous.length;
  return _computeDelta(current: curAvg, previous: prevAvg, lowerIsBetter: true);
});

final focusTimeDeltaProvider = Provider<TrendDelta>((ref) {
  final current = ref.watch(weeklyFocusSecondsProvider).valueOrNull;
  final previous = ref.watch(previousWeekFocusSecondsProvider).valueOrNull;
  if (current == null || previous == null) return TrendDelta.none;
  return _computeDelta(
      current: current.toDouble(), previous: previous.toDouble(), lowerIsBetter: false);
});

final pickupsDeltaProvider = Provider<TrendDelta>((ref) {
  final current = ref.watch(weeklyPickupsProvider).valueOrNull;
  final previous = ref.watch(previousWeekPickupsProvider).valueOrNull;
  if (current == null || previous == null) return TrendDelta.none;
  final curAvg = current.isEmpty ? 0.0 : current.reduce((a, b) => a + b) / current.length;
  final prevAvg = previous.isEmpty ? 0.0 : previous.reduce((a, b) => a + b) / previous.length;
  return _computeDelta(current: curAvg, previous: prevAvg, lowerIsBetter: true);
});
