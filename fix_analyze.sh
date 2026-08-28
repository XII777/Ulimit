#!/usr/bin/env bash
# Fixes flutter analyze: unused import (home_data_providers.dart),
# missing const (home_screen.dart empty-state), and an optional
# parameter that was never explicitly passed (focus_screen.dart).
set -e

if [ ! -f pubspec.yaml ]; then
  echo "Run this from inside your repo root (where pubspec.yaml lives)."
  exit 1
fi

mkdir -p "lib/data"
cat > "lib/data/home_data_providers.dart" << 'PATCH_EOF'
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
PATCH_EOF

mkdir -p "lib/features/home"
cat > "lib/features/home/home_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/providers.dart';
import '../../data/home_data_providers.dart';
import '../../shared/widgets/limit_ring.dart';
import '../../shared/widgets/trend_chart.dart';
import '../../shared/widgets/pressable_scale.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenTime = ref.watch(todayScreenTimeProvider);
    final budgetMinutes = ref.watch(dailyBudgetProvider);
    final score = ref.watch(limitScoreProvider);
    final streak = ref.watch(currentStreakProvider);
    final weeklyUsage = ref.watch(weeklyScreenTimeHoursProvider);
    final weeklyFocusSeconds = ref.watch(weeklyFocusSecondsProvider);
    final weeklyFocusHours = ref.watch(weeklyFocusHoursByDayProvider);
    final weeklyPickups = ref.watch(weeklyPickupsProvider);

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topCenter,
          radius: 1.15,
          colors: [Color(0x3A8B7FE8), Colors.transparent],
          stops: [0.0, 0.6],
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
          children: [
            _Header(streak: streak.valueOrNull ?? 0),
            const SizedBox(height: 18),

            _LimitScoreBanner(score: score),
            const SizedBox(height: 22),

            Center(
              child: _buildRing(screenTime, budgetMinutes),
            ),
            const SizedBox(height: 28),

            const _SectionLabel('THIS WEEK'),
            const SizedBox(height: 10),
            _WeeklyTrendCard(weeklyHours: weeklyUsage),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _MiniTrendCard(
                    label: 'Focus time',
                    valueText: _formatFocusTotal(weeklyFocusSeconds.valueOrNull),
                    values: weeklyFocusHours.valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MiniTrendCard(
                    label: 'Pickups / day',
                    valueText: _formatPickupsAvg(weeklyPickups.valueOrNull),
                    values: weeklyPickups.valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),

            const _SectionLabel('CONTROLS'),
            const SizedBox(height: 10),
            const _ControlsGrid(),
          ],
        ),
      ),
    );
  }

  Widget _buildRing(AsyncValue<Duration> screenTime, AsyncValue<int> budgetMinutes) {
    if (screenTime.isLoading || budgetMinutes.isLoading) {
      return const LimitRing(progress: 0, size: 130, trackColor: AppColors.stroke);
    }
    final used = screenTime.valueOrNull ?? Duration.zero;
    final budget = Duration(minutes: budgetMinutes.valueOrNull ?? 240);
    return _ScreenTimeRing(used: used, budget: budget);
  }

  String _formatFocusTotal(int? seconds) {
    if (seconds == null || seconds == 0) return '0m';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }

  String _formatPickupsAvg(List<double>? days) {
    if (days == null || days.isEmpty) return '—';
    final avg = days.reduce((a, b) => a + b) / days.length;
    return avg.round().toString();
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.streak});
  final int streak;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Today', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text(_formattedDate(), style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        if (streak > 0) _StreakBadge(days: streak),
      ],
    );
  }

  String _formattedDate() {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final now = DateTime.now();
    return '${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
  }
}

class _StreakBadge extends StatelessWidget {
  const _StreakBadge({required this.days});
  final int days;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_fire_department_rounded, size: 13, color: AppColors.accentSoft),
          const SizedBox(width: 5),
          Text('$days day streak',
              style: const TextStyle(fontSize: 11, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.labelSmall);
}

class _ScreenTimeRing extends StatelessWidget {
  const _ScreenTimeRing({required this.used, required this.budget});
  final Duration used;
  final Duration budget;

  @override
  Widget build(BuildContext context) {
    final remaining = budget - used;
    final safeBudget = budget.inSeconds <= 0 ? 1 : budget.inSeconds;
    final progress = 1 - (used.inSeconds / safeBudget).clamp(0.0, 1.0);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: progress),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: AppColors.accent.withOpacity(0.18), blurRadius: 40, spreadRadius: 4),
          ],
        ),
        child: LimitRing(
          progress: value,
          size: 130,
          strokeWidth: 9,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_formatDuration(remaining), style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text('LEFT TODAY', style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final clamped = d.isNegative ? Duration.zero : d;
    final h = clamped.inHours;
    final m = clamped.inMinutes % 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _LimitScoreBanner extends StatelessWidget {
  const _LimitScoreBanner({required this.score});
  final AsyncValue<LimitScore> score;

  @override
  Widget build(BuildContext context) {
    final data = score.valueOrNull;

    return PressableScale(
      onTap: () {}, // wire to Routes.score detail push
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.stroke),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [AppColors.accent.withOpacity(0.14), AppColors.surface],
            stops: const [0.0, 0.65],
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(colors: [AppColors.accent, AppColors.accentSoft, AppColors.accent]),
              ),
              child: Center(
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(color: AppColors.surface, shape: BoxShape.circle),
                  child: const Icon(Icons.shield_rounded, size: 18, color: AppColors.ink),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(data == null ? '—' : '${data.score}',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 6),
                      Text('Limit',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600, color: AppColors.inkDim)),
                    ],
                  ),
                  Text(
                    data == null
                        ? 'Calculating…'
                        : '${data.tier.name} tier · ${data.toNextTier} to next badge',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.accent, size: 18),
          ],
        ),
      ),
    );
  }
}

class _WeeklyTrendCard extends StatelessWidget {
  const _WeeklyTrendCard({required this.weeklyHours});
  final AsyncValue<List<double>> weeklyHours;

  @override
  Widget build(BuildContext context) {
    final values = weeklyHours.valueOrNull;
    final hasData = values != null && values.any((v) => v > 0);
    final avg = hasData ? values.reduce((a, b) => a + b) / values.length : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Avg. daily screen time',
              style: TextStyle(fontSize: 12, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            hasData ? _formatHours(avg) : 'No data yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          if (hasData)
            TrendAreaChart(values: values)
          else
            // First-run / no-Accessibility-permission state — an empty
            // chart card reads as broken, so say so explicitly instead.
            const SizedBox(
              height: 84,
              child: Center(
                child: Text(
                  'Enable Accessibility access to start tracking',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: AppColors.inkFaint),
                ),
              ),
            ),
          const SizedBox(height: 4),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _DayLabel('M'), _DayLabel('T'), _DayLabel('W'), _DayLabel('T'),
              _DayLabel('F'), _DayLabel('S'), _DayLabel('S'),
            ],
          ),
        ],
      ),
    );
  }

  String _formatHours(double hours) {
    final h = hours.floor();
    final m = ((hours - h) * 60).round();
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 9, color: AppColors.inkFaint));
}

class _MiniTrendCard extends StatelessWidget {
  const _MiniTrendCard({
    required this.label,
    required this.valueText,
    required this.values,
  });

  final String label;
  final String valueText;
  final List<double> values;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Sparkline(values: values),
          const SizedBox(height: 6),
          Text(valueText,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _ControlsGrid extends StatelessWidget {
  const _ControlsGrid();

  static const _tiles = [
    ('Focus', Icons.track_changes_rounded, 'Start a session'),
    ('App Limits', Icons.grid_view_rounded, 'Manage groups'),
    ('App Blocking', Icons.block_rounded, 'Manage blocked apps'),
    ('Internet & Sites', Icons.public_rounded, 'VPN & filters'),
    ('Notifications', Icons.notifications_rounded, 'Manage delivery'),
    ('Bedtime', Icons.dark_mode_rounded, 'Manage schedule'),
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _tiles.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 9,
        crossAxisSpacing: 9,
        childAspectRatio: 1.5,
      ),
      itemBuilder: (context, i) {
        final (title, icon, subtitle) = _tiles[i];
        return _ControlTile(title: title, icon: icon, subtitle: subtitle);
      },
    );
  }
}

class _ControlTile extends StatelessWidget {
  const _ControlTile({required this.title, required this.icon, required this.subtitle});
  final String title;
  final IconData icon;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: () {},
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 15, color: AppColors.accentSoft),
            ),
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 12.5)),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10)),
          ],
        ),
      ),
    );
  }
}
PATCH_EOF

mkdir -p "lib/features/focus"
cat > "lib/features/focus/focus_screen.dart" << 'PATCH_EOF'
import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';
import '../../shared/widgets/limit_ring.dart';

class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  static const _total = Duration(minutes: 25);
  Duration _remaining = _total;
  Timer? _ticker;

  // Placeholder — swap for a real todaysSessionsProvider (Drift query on
  // FocusSessions where startedAt is today) once that lands. Matches the
  // 3-dot pattern in the design: completed sessions filled, the current
  // one shown as an accent-to-calm gradient chip, empty slots as tracks.
  static const _completedSessions = 2;

  @override
  void initState() {
    super.initState();
    // A 1-second periodic timer is cheap — the ring's own repaint is
    // gated by shouldRepaint, so this doesn't cost more than one
    // CustomPainter.paint() per second, not per frame.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_remaining.inSeconds <= 0) {
        _ticker?.cancel();
        return;
      }
      setState(() => _remaining -= const Duration(seconds: 1));
    });
  }

  @override
  void dispose() {
    _ticker?.cancel(); // leaking this timer is the #1 cause of
    // "why does my app get slower the longer it's open" bug reports
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = 1 - (_remaining.inSeconds / _total.inSeconds);

    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.6),
          radius: 1.0,
          colors: [Color(0xFF191533), AppColors.bg],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            const _InvincibleChip(),
            const Spacer(),
            LimitRing(
              progress: progress,
              size: 220,
              strokeWidth: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_format(_remaining), style: const TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    fontSize: 38,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  )),
                  const SizedBox(height: 6),
                  Text('Deep Work · remaining', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _LockNote(),
            const Spacer(),
            const _TodaysSessions(completed: _completedSessions, total: 3),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => _confirmEndEarly(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(14),
                    backgroundColor: AppColors.surface2,
                    side: const BorderSide(color: AppColors.stroke),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: const Text('End session early', style: TextStyle(color: AppColors.inkDim)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _format(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _confirmEndEarly(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (_) => const SizedBox(height: 160, child: Center(child: Text('Confirm sheet — wire to session provider'))),
    );
  }
}

class _InvincibleChip extends StatelessWidget {
  const _InvincibleChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.14),
        border: Border.all(color: AppColors.accent.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 12, color: AppColors.accentSoft),
          SizedBox(width: 6),
          Text('Invincible mode on', style: TextStyle(fontSize: 11.5, color: AppColors.accentSoft)),
        ],
      ),
    );
  }
}

/// "12 apps paused · DND on" — reinforces what invincible mode is
/// actually doing while the ring runs, so the state isn't only
/// communicated once at the top of the screen.
class _LockNote extends StatelessWidget {
  const _LockNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.notifications_off_rounded, size: 13, color: AppColors.inkFaint),
        const SizedBox(width: 6),
        Text('12 apps paused · DND on', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5)),
      ],
    );
  }
}

class _TodaysSessions extends StatelessWidget {
  const _TodaysSessions({required this.completed, this.total = 3});
  final int completed;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          "TODAY'S SESSIONS",
          style: Theme.of(context).textTheme.labelSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < total; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _SessionDot(state: i < completed
                  ? _SessionState.done
                  : i == completed
                      ? _SessionState.active
                      : _SessionState.empty),
            ],
          ],
        ),
      ],
    );
  }
}

enum _SessionState { done, active, empty }

class _SessionDot extends StatelessWidget {
  const _SessionDot({required this.state});
  final _SessionState state;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case _SessionState.active:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.accent, AppColors.calm],
            ),
            border: Border.all(color: AppColors.accent, width: 3),
          ),
        );
      case _SessionState.done:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.accent.withOpacity(0.25),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.accent),
          ),
          child: const Icon(Icons.check_rounded, size: 16, color: AppColors.accentSoft),
        );
      case _SessionState.empty:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.stroke),
          ),
        );
    }
  }
}
PATCH_EOF

git add -A
git -c user.email="dev@ulimit.app" -c user.name="Ulimit Dev" commit -m "Fix flutter analyze: unused import, missing const, unused-default parameter"
git push

echo "Pushed. Removing this script."
rm -- "$0"
