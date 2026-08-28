import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _daysAgo(int n) => _startOfDay(DateTime.now().subtract(Duration(days: n)));

/// The user's configured daily budget, in minutes. Falls back to the
/// schema default (240) via Drift's own default value if no Profile
/// row exists yet — a fresh install still gets a sane ring.
final dailyBudgetProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.profile).watchSingleOrNull().map((row) => row?.dailyBudgetMinutes ?? 240);
});

/// Last 7 days of total screen time, oldest→newest, in hours — feeds
/// the weekly trend chart directly. Real query, not a fixture array.
final weeklyScreenTimeHoursProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.appUsage)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final byDay = <DateTime, int>{};
    for (final r in rows) {
      byDay.update(r.day, (v) => v + r.foregroundSeconds, ifAbsent: () => r.foregroundSeconds);
    }
    return List.generate(7, (i) {
      final day = _daysAgo(6 - i);
      final seconds = byDay[day] ?? 0;
      return seconds / 3600.0;
    });
  });
});

/// Daily focus-session totals for the last 7 days, oldest→newest, in
/// hours — mirrors weeklyScreenTimeHoursProvider's shape so both feed
/// the same chart widgets consistently.
final weeklyFocusHoursByDayProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.focusSessions)
    ..where((t) => t.startedAt.isBiggerOrEqualValue(start) & t.completed.equals(true));

  return query.watch().map((rows) {
    final byDay = <DateTime, int>{};
    for (final s in rows) {
      if (s.endedAt == null) continue;
      final day = _startOfDay(s.startedAt);
      final seconds = s.endedAt!.difference(s.startedAt).inSeconds;
      byDay.update(day, (v) => v + seconds, ifAbsent: () => seconds);
    }
    return List.generate(7, (i) {
      final day = _daysAgo(6 - i);
      return (byDay[day] ?? 0) / 3600.0;
    });
  });
});

/// Total completed focus-session time this week, in seconds.
final weeklyFocusSecondsProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.focusSessions)
    ..where((t) => t.startedAt.isBiggerOrEqualValue(start) & t.completed.equals(true));

  return query.watch().map((rows) => rows.fold<int>(0, (sum, s) {
        if (s.endedAt == null) return sum;
        return sum + s.endedAt!.difference(s.startedAt).inSeconds;
      }));
});

/// Daily pickup counts for the last 7 days, oldest→newest.
final weeklyPickupsProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.pickupsLog)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final byDay = {for (final r in rows) r.day: r.count};
    return List.generate(7, (i) {
      final day = _daysAgo(6 - i);
      return (byDay[day] ?? 0).toDouble();
    });
  });
});

/// Consecutive-day streak, computed from days that have *any* recorded
/// AppUsage row — i.e. the app was actually used/tracked that day.
/// Walks backward from today; breaks on the first missing day.
final currentStreakProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(60); // 60-day lookback is plenty for any realistic streak

  final query = db.select(db.appUsage)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final daysWithData = rows.map((r) => r.day).toSet();
    var streak = 0;
    var cursor = _startOfDay(DateTime.now());
    while (daysWithData.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  });
});

/// The Limit score badge tiers, per the design system — 0 to 1000 in
/// 10 bands. Kept alongside the calculation so a UI never has to
/// hardcode a tier name against a score by hand.
class ScoreTier {
  const ScoreTier(this.name, this.min, this.max);
  final String name;
  final int min;
  final int max;
}

const scoreTiers = [
  ScoreTier('Newcomer', 0, 99),
  ScoreTier('Aware', 100, 199),
  ScoreTier('Steady', 200, 299),
  ScoreTier('Disciplined', 300, 399),
  ScoreTier('Focused', 400, 499),
  ScoreTier('Resolute', 500, 599),
  ScoreTier('Mindful', 600, 699),
  ScoreTier('Unshaken', 700, 799),
  ScoreTier('Sovereign', 800, 899),
  ScoreTier('Limitless', 900, 1000),
];

ScoreTier tierFor(int score) =>
    scoreTiers.firstWhere((t) => score >= t.min && score <= t.max, orElse: () => scoreTiers.first);

class LimitScore {
  const LimitScore({required this.score, required this.tier, required this.toNextTier});
  final int score;
  final ScoreTier tier;
  final int toNextTier;
}

/// Real weighted calculation from the design doc's formula — screen-time
/// reduction 35%, focus consistency 30%, streak 20%, limits kept 15% —
/// computed live from today's actual data rather than a fixture. Each
/// component is normalized to 0–1 before weighting so the formula stays
/// meaningful regardless of how ambitious someone's budget is.
final limitScoreProvider = Provider<AsyncValue<LimitScore>>((ref) {
  final weeklyUsage = ref.watch(weeklyScreenTimeHoursProvider);
  final weeklyFocus = ref.watch(weeklyFocusSecondsProvider);
  final streak = ref.watch(currentStreakProvider);
  final budget = ref.watch(dailyBudgetProvider);

  // Combine four AsyncValues manually rather than pulling in a
  // multi-provider-combinator package for one screen's worth of use.
  if (weeklyUsage.isLoading || weeklyFocus.isLoading || streak.isLoading || budget.isLoading) {
    return const AsyncValue.loading();
  }
  final usage = weeklyUsage.valueOrNull;
  final focusSeconds = weeklyFocus.valueOrNull;
  final streakDays = streak.valueOrNull;
  final budgetMinutes = budget.valueOrNull;
  if (usage == null || focusSeconds == null || streakDays == null || budgetMinutes == null) {
    return const AsyncValue.loading();
  }

  final budgetHours = budgetMinutes / 60.0;
  final avgUsedHours = usage.isEmpty ? 0.0 : usage.reduce((a, b) => a + b) / usage.length;
  final screenTimeComponent = (1 - (avgUsedHours / (budgetHours <= 0 ? 1 : budgetHours))).clamp(0.0, 1.0);

  // 5 focused hours/week treated as "full marks" for consistency —
  // arbitrary but reasonable target; tune once real usage data exists.
  final focusConsistencyComponent = (focusSeconds / (5 * 3600)).clamp(0.0, 1.0);

  final streakComponent = (streakDays / 30).clamp(0.0, 1.0); // 30-day streak = full marks

  // Limits-kept component needs RestrictionGroups override/breach
  // tracking, which isn't built yet — held at a neutral 0.7 rather than
  // faking a precise number until that data source exists.
  const limitsKeptComponent = 0.7;

  final total = (screenTimeComponent * 0.35) +
      (focusConsistencyComponent * 0.30) +
      (streakComponent * 0.20) +
      (limitsKeptComponent * 0.15);

  final score = (total * 1000).round().clamp(0, 1000);
  final tier = tierFor(score);
  final toNext = tier.max >= 1000 ? 0 : (tier.max + 1 - score);

  return AsyncValue.data(LimitScore(score: score, tier: tier, toNextTier: toNext));
});
