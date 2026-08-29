#!/usr/bin/env bash
# Home screen redesign: lightweight lime/red gamification layer over
# the existing real-data architecture (per the detailed design brief).
#
# What's real and new:
#  - Top atmospheric lime gradient (static, single layer, no per-frame cost)
#  - Central ring, weekly chart, sparklines recolored lime
#  - Real week-over-week delta badges (new 14-day-comparison providers,
#    not fabricated) with correct semantic lime/red + up/down arrows
#  - RollingNumber: only changed digits animate (score, ring time,
#    streak count, mini-card values)
#  - Streak icon pulses+glows on real streak increase (IncreasePulse)
#  - Micro-achievement toast ('Streak continued') triggered by the real
#    currentStreakProvider going up -- no fake events
#  - Nav bar active pill recolored lime
#  - Threshold-based swipe-between-tabs on the nav shell (see scoping
#    note in nav_shell.dart -- not a full finger-tracked PageView, to
#    avoid fighting each tab's own vertical scroll views)
#
# Colors are added as NEW tokens (AppColors.homeLime/homeNegative),
# scoped to Home only -- the rest of the app keeps its existing violet
# accent system untouched, per 'preserve existing architecture.'
set -e

if [ ! -f pubspec.yaml ]; then
  echo "Run this from inside your repo root (where pubspec.yaml lives)."
  exit 1
fi

mkdir -p "lib/core/theme"
cat > "lib/core/theme/tokens.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';

/// Design tokens. The ring/bar/badge language communicates state through
/// exactly three colors — pick one of these, never an ad-hoc color:
///   - [accent] (violet) — the primary brand color: focus sessions, chart
///     lines, anything that isn't a live "budget state" signal.
///   - [calm] (teal) — on track / plenty of budget left.
///   - [alert] (amber) — near your limit, AND the blocking-overlay /
///     invincible-lock state. One color for both on purpose: a live
///     warning ring and the overlay it leads to are the same state,
///     not two different ones.
abstract final class AppColors {
  static const bg = Color(0xFF0F1116);
  static const surface = Color(0xFF1A1D25);
  static const surface2 = Color(0xFF22262F);
  static const stroke = Color(0xFF2C303A);

  static const ink = Color(0xFFF2F1EC);
  static const inkDim = Color(0xFF9497A3);
  static const inkFaint = Color(0xFF5C606C);

  /// Primary brand accent.
  static const accent = Color(0xFF8B7FE8);
  static const accentSoft = Color(0xFFB7AEF5);

  /// On-track / plenty-of-budget ring & badge state.
  static const calm = Color(0xFF5FC9AE);

  /// Near-limit warning AND blocking-overlay / invincible-lock state.
  static const alert = Color(0xFFF2A94D);
  static const danger = Color(0xFFE8697A);

  /// Home screen's gamified progress/trend colors — deliberately scoped
  /// to Home only (per that screen's specific design brief), not a
  /// replacement for [accent] elsewhere in the app. Comparable
  /// saturation/intensity by design: green and red should read as
  /// equally vivid opposites, not "vivid positive, muted negative."
  static const homeLime = Color(0xFFAEFF00);
  static const homeNegative = Color(0xFFFF3B3B);
}

abstract final class AppRadius {
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 28.0;
  static const pill = 100.0;
}

/// Spacing scale — 4pt grid. Resist inventing one-off paddings; pick
/// from here so density stays consistent without a design review.
abstract final class AppSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Type scale — trimmed to Android Material guidelines rather than
/// marketing-mockup sizes. See learnui.design/android type scale.
abstract final class AppText {
  static const headline = 20.0; // screen titles (~H6)
  static const title = 16.0; // card / section titles (Subtitle1)
  static const body = 14.0; // body copy (Body2)
  static const caption = 12.0; // metadata, timestamps
  static const overline = 10.5; // eyebrow labels, letter-spaced
  static const hero = 38.0; // one-per-screen hero numbers only
}
PATCH_EOF

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
      byDay.update(r.day, (v) => v + r.foregroundSeconds, ifAbsent: () => r.foregroundSeconds);
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
final previousWeekPickupsProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(13);
  final end = _daysAgo(7);

  final query = db.select(db.pickupsLog)
    ..where((t) => t.day.isBiggerOrEqualValue(start) & t.day.isSmallerThanValue(end));

  return query.watch().map((rows) {
    final byDay = {for (final r in rows) r.day: r.count};
    return List.generate(7, (i) {
      final day = _daysAgo(13 - i);
      return (byDay[day] ?? 0).toDouble();
    });
  });
});

/// A single "up X% / down X%" result, with the semantic direction
/// already resolved — screen-time-down and pickups-down are both
/// "good" (green), but focus-time-down is "bad" (red). Each call site
/// tells this which direction counts as positive rather than this
/// class guessing from the sign alone.
class TrendDelta {
  const TrendDelta({required this.percent, required this.isPositive, required this.hasData});
  final double percent; // always positive magnitude; sign shown via arrow/color
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
  final magnitude = (change.abs() * 100);
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

mkdir -p "lib/shared/widgets"
cat > "lib/shared/widgets/nav_shell.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/tokens.dart';
import '../../core/router/app_router.dart';

class NavShell extends StatelessWidget {
  const NavShell({super.key, required this.child});
  final Widget child;

  static const _tabs = [
    (Routes.home, Icons.home_rounded, 'Home'),
    (Routes.focus, Icons.track_changes_rounded, 'Focus'),
    (Routes.limits, Icons.grid_view_rounded, 'Limits'),
    (Routes.bedtime, Icons.dark_mode_rounded, 'Bedtime'),
    (Routes.settings, Icons.settings_rounded, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;

    final activeIndex = _tabs.indexWhere((t) => t.$1 == location).clamp(0, 4);

    void goToTab(int index) {
      if (index < 0 || index >= _tabs.length || index == activeIndex) return;
      context.go(_tabs[index].$1);
    }

    return Scaffold(
      // `child` is the current tab's screen; Stack lets the nav float
      // over it without stealing layout space, matching the mockup.
      body: Stack(
        children: [
          GestureDetector(
            // A horizontal-only gesture recognizer would still fire on
            // primarily-vertical drags; gating on velocity magnitude in
            // onHorizontalDragEnd (rather than onHorizontalDragUpdate)
            // means this only acts on a deliberate, fast horizontal
            // flick, so normal vertical scrolling on any tab's content
            // is never intercepted or fights with this gesture.
            onHorizontalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              const threshold = 300.0;
              if (velocity < -threshold) {
                goToTab(activeIndex + 1);
              } else if (velocity > threshold) {
                goToTab(activeIndex - 1);
              }
            },
            child: child,
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: _FloatingNavBar(
              tabs: _tabs,
              activeIndex: activeIndex,
              onTap: goToTab,
            ),
          ),
        ],
      ),
    );
  }
}

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.tabs,
    required this.activeIndex,
    required this.onTap,
  });

  final List<(String, IconData, String)> tabs;
  final int activeIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0C10),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.55),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(tabs.length, (i) {
          final isActive = i == activeIndex;
          final (_, icon, label) = tabs[i];
          return _NavItem(
            icon: icon,
            label: label,
            isActive: isActive,
            onTap: () => onTap(i),
          );
        }),
      ),
    );
  }
}

/// The morph: an AnimatedContainer widens from an icon-only circle into
/// an icon+label pill. AnimatedContainer is the right tool here — it's
/// implicitly driven by the widget tree diff, so there's no
/// AnimationController to leak or forget to dispose, and Flutter batches
/// the size/color tween into a single compositor-friendly pass.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        height: 38,
        padding: EdgeInsets.symmetric(horizontal: isActive ? 14 : 0),
        decoration: BoxDecoration(
          color: isActive ? AppColors.homeLime : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 38,
              child: Icon(
                icon,
                size: 18,
                color: isActive ? AppColors.bg : AppColors.inkFaint,
              ),
            ),
            // AnimatedSize + fade avoids laying out invisible text every
            // frame for the four inactive tabs — cheaper than always
            // building the label and toggling opacity to zero.
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: isActive
                  ? Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Text(
                        label,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.bg,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
PATCH_EOF

mkdir -p "lib/features/home"
cat > "lib/features/home/home_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/tokens.dart';
import '../../data/providers.dart';
import '../../data/home_data_providers.dart';
import '../../shared/widgets/limit_ring.dart';
import '../../shared/widgets/trend_chart.dart';
import '../../shared/widgets/pressable_scale.dart';
import '../../shared/widgets/rolling_number.dart';
import '../../shared/widgets/increase_pulse.dart';
import '../../shared/widgets/achievement_toast.dart';

// Colocated UI-ephemeral state (not real app data, just "what should the
// achievement toast say right now") — kept here rather than in
// home_data_providers.dart since nothing outside this screen needs it.
final _achievementMessageProvider = StateProvider<String?>((ref) => null);
final _lastSeenStreakProvider = StateProvider<int?>((ref) => null);

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
    final screenTimeDelta = ref.watch(screenTimeDeltaProvider);
    final focusDelta = ref.watch(focusTimeDeltaProvider);
    final pickupsDelta = ref.watch(pickupsDeltaProvider);

    // Real streak increases trigger the micro-achievement toast — no
    // fabricated events, this only fires off currentStreakProvider's
    // actual value going up versus what we last saw it at.
    ref.listen(currentStreakProvider, (previous, next) {
      final value = next.valueOrNull;
      if (value == null) return;
      final lastSeen = ref.read(_lastSeenStreakProvider);
      if (lastSeen != null && value > lastSeen) {
        ref.read(_achievementMessageProvider.notifier).state = 'Streak continued';
      }
      ref.read(_lastSeenStreakProvider.notifier).state = value;
    });
    final achievementMessage = ref.watch(_achievementMessageProvider);

    return DecoratedBox(
      // Atmospheric top gradient: strong through the first quarter of
      // the screen, tapering smoothly by ~60% down, gone well before
      // the bottom half. A single static LinearGradient — no per-frame
      // cost, no blur, just alpha-stepped stops so there's no visible
      // seam.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, 0.25, 0.35, 0.6],
          colors: [
            Color(0x59AEFF00), // ~35% opacity homeLime
            Color(0x4DAEFF00), // ~30%
            Color(0x14AEFF00), // ~8%, fading
            Colors.transparent,
          ],
        ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            ListView(
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
                _WeeklyTrendCard(weeklyHours: weeklyUsage, delta: screenTimeDelta),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _MiniTrendCard(
                        label: 'Focus time',
                        valueText: _formatFocusTotal(weeklyFocusSeconds.valueOrNull),
                        values: weeklyFocusHours.valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0],
                        delta: focusDelta,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MiniTrendCard(
                        label: 'Pickups / day',
                        valueText: _formatPickupsAvg(weeklyPickups.valueOrNull),
                        values: weeklyPickups.valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0],
                        delta: pickupsDelta,
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

            // Achievement toast floats above the scroll content, top-
            // anchored under the header. IgnorePointer inside it means
            // it never steals a scroll/tap even while visible.
            Positioned(
              top: 4,
              left: 20,
              right: 20,
              child: Align(
                alignment: Alignment.topCenter,
                child: AchievementToast(message: achievementMessage, accentColor: AppColors.homeLime),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRing(AsyncValue<Duration> screenTime, AsyncValue<int> budgetMinutes) {
    if (screenTime.isLoading || budgetMinutes.isLoading) {
      return const LimitRing(
          progress: 0, size: 130, trackColor: AppColors.stroke, color: AppColors.homeLime);
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
        color: AppColors.surface.withOpacity(0.85),
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IncreasePulse(
            value: days,
            glowColor: AppColors.homeLime,
            child: const Icon(Icons.local_fire_department_rounded, size: 13, color: AppColors.homeLime),
          ),
          const SizedBox(width: 5),
          RollingNumber(
            text: '$days',
            style: const TextStyle(fontSize: 11, color: AppColors.ink, fontWeight: FontWeight.w700),
          ),
          const Text(' day streak',
              style: TextStyle(fontSize: 11, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
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
            BoxShadow(color: AppColors.homeLime.withOpacity(0.22), blurRadius: 36, spreadRadius: 2),
          ],
        ),
        child: LimitRing(
          progress: value,
          size: 130,
          strokeWidth: 9,
          color: AppColors.homeLime,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RollingNumber(
                text: _formatDuration(remaining),
                style: Theme.of(context).textTheme.headlineSmall ?? const TextStyle(),
              ),
              const SizedBox(height: 2),
              Text('LEFT TODAY',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: AppColors.homeLime.withOpacity(0.75))),
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
    // Progress toward the next tier, for the subtle ring behind the
    // shield icon — reuses the same score data already on screen
    // rather than inventing a second progress source.
    final tierSpan = data == null ? 1 : (data.tier.max - data.tier.min + 1);
    final intoTier = data == null ? 0 : (data.score - data.tier.min);
    final tierProgress = data == null ? 0.0 : (intoTier / tierSpan).clamp(0.0, 1.0);

    return PressableScale(
      onTap: () {}, // wire to Routes.score detail push
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.stroke),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [AppColors.homeLime.withOpacity(0.10), AppColors.surface],
            stops: const [0.0, 0.65],
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: tierProgress),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => LimitRing(
                      progress: value,
                      size: 44,
                      strokeWidth: 3,
                      color: AppColors.homeLime,
                      trackColor: AppColors.stroke,
                    ),
                  ),
                  Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(color: AppColors.surface, shape: BoxShape.circle),
                    child: const Icon(Icons.shield_rounded, size: 16, color: AppColors.ink),
                  ),
                ],
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
                      data == null
                          ? const Text('—', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700))
                          : RollingNumber(
                              text: '${data.score}',
                              style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(fontSize: 19, fontWeight: FontWeight.w700) ??
                                  const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                            ),
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
            const Icon(Icons.chevron_right_rounded, color: AppColors.homeLime, size: 18),
          ],
        ),
      ),
    );
  }
}

class _WeeklyTrendCard extends StatelessWidget {
  const _WeeklyTrendCard({required this.weeklyHours, required this.delta});
  final AsyncValue<List<double>> weeklyHours;
  final TrendDelta delta;

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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Avg. daily screen time',
                  style: TextStyle(fontSize: 12, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
              if (delta.hasData) _DeltaBadge(delta: delta),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            hasData ? _formatHours(avg) : 'No data yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          if (hasData)
            TrendAreaChart(values: values, color: AppColors.homeLime)
          else
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

/// The one place positive/negative semantic color is decided —
/// [TrendDelta.isPositive] already encodes "is this actually good"
/// (e.g. less screen time is good, more focus time is good), so this
/// widget just renders that, it never re-derives direction from a
/// raw sign.
class _DeltaBadge extends StatelessWidget {
  const _DeltaBadge({required this.delta});
  final TrendDelta delta;

  @override
  Widget build(BuildContext context) {
    final color = delta.isPositive ? AppColors.homeLime : AppColors.homeNegative;
    final arrow = delta.isPositive ? '▲' : '▼';
    return Text(
      '$arrow ${delta.percent.round()}%',
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w700),
    );
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
    required this.delta,
  });

  final String label;
  final String valueText;
  final List<double> values;
  final TrendDelta delta;

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
          Sparkline(values: values, color: AppColors.homeLime),
          const SizedBox(height: 6),
          RollingNumber(
            text: valueText,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w700) ??
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (delta.hasData) ...[
            const SizedBox(height: 2),
            _DeltaBadge(delta: delta),
          ],
        ],
      ),
    );
  }
}

class _ControlsGrid extends StatelessWidget {
  const _ControlsGrid();

  static const _tiles = [
    ('Focus', Icons.track_changes_rounded, 'Start a session', null),
    ('App Limits', Icons.grid_view_rounded, 'Manage groups', null),
    ('App Blocking', Icons.block_rounded, 'Manage blocked apps', null),
    ('Internet & Sites', Icons.public_rounded, 'VPN & filters', null),
    ('Notifications', Icons.notifications_rounded, 'Manage delivery', null),
    ('Bedtime', Icons.dark_mode_rounded, 'Manage schedule', null),
    ('Parental & Lock', Icons.shield_rounded, 'Device admin & tamper protection', Routes.parental),
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
        final (title, icon, subtitle, route) = _tiles[i];
        return _ControlTile(title: title, icon: icon, subtitle: subtitle, route: route);
      },
    );
  }
}

class _ControlTile extends StatelessWidget {
  const _ControlTile({required this.title, required this.icon, required this.subtitle, this.route});
  final String title;
  final IconData icon;
  final String subtitle;
  final String? route;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: route == null ? () {} : () => context.push(route!),
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
                color: AppColors.homeLime.withOpacity(0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 15, color: AppColors.homeLime),
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

mkdir -p "lib/shared/widgets"
cat > "lib/shared/widgets/rolling_number.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';

/// A number/string display where only the characters that actually
/// changed between updates animate — "475" → "476" rolls just the "5",
/// not the whole string. Built as a plain AnimatedSwitcher-per-character
/// rather than a hand-tracked continuous-scroll odometer: it's far
/// cheaper (no per-frame drag/velocity math, no extra ticker beyond
/// what AnimatedSwitcher already uses), and for values that update at
/// most a few times a minute the crossfade+slide reads as a genuine
/// "roll" without the performance risk of a bespoke scroll physics
/// implementation.
class RollingNumber extends StatefulWidget {
  const RollingNumber({
    super.key,
    required this.text,
    required this.style,
    this.duration = const Duration(milliseconds: 320),
  });

  final String text;
  final TextStyle style;
  final Duration duration;

  @override
  State<RollingNumber> createState() => _RollingNumberState();
}

class _RollingNumberState extends State<RollingNumber> {
  String? _previousText;

  @override
  void didUpdateWidget(RollingNumber old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _previousText = old.text;
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.text;
    final previous = _previousText;

    // Character-by-character diff against the previous value. Different
    // lengths (e.g. "9" -> "10") fall back to animating the whole
    // string — a digit-by-digit diff across a length change would need
    // right-alignment/carry logic disproportionate to how rarely this
    // app's numbers cross a digit-count boundary.
    final sameLength = previous != null && previous.length == current.length;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(current.length, (i) {
        final char = current[i];
        final changed = !sameLength || previous[i] != char;

        return ClipRect(
          child: AnimatedSwitcher(
            duration: widget.duration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              final slideIn = Tween<Offset>(
                begin: const Offset(0, 0.6),
                end: Offset.zero,
              ).animate(animation);
              final slideOut = Tween<Offset>(
                begin: Offset.zero,
                end: const Offset(0, -0.6),
              ).animate(animation);
              // Outgoing digit slides up+fades, incoming slides in from
              // below+fades — the classic odometer look, per-character.
              return ClipRect(
                child: SlideTransition(
                  position: child.key == ValueKey('$char-$i-new') ? slideIn : slideOut,
                  child: FadeTransition(opacity: animation, child: child),
                ),
              );
            },
            child: Text(
              char,
              key: changed ? ValueKey('$char-$i-new') : ValueKey('static-$i-$char'),
              style: widget.style,
            ),
          ),
        );
      }),
    );
  }
}
PATCH_EOF

mkdir -p "lib/shared/widgets"
cat > "lib/shared/widgets/increase_pulse.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';

/// Wraps [child] and briefly scales + glows it whenever [value] increases
/// versus the last build — used for the streak flame icon. A single
/// AnimatedContainer + AnimatedScale pair, no continuous ticker running
/// in the background when idle, so it costs nothing between streak
/// increments.
class IncreasePulse extends StatefulWidget {
  const IncreasePulse({
    super.key,
    required this.value,
    required this.child,
    this.glowColor = const Color(0xFFAEFF00),
  });

  final int value;
  final Widget child;
  final Color glowColor;

  @override
  State<IncreasePulse> createState() => _IncreasePulseState();
}

class _IncreasePulseState extends State<IncreasePulse> {
  bool _pulsing = false;
  int? _lastValue;

  @override
  void didUpdateWidget(IncreasePulse old) {
    super.didUpdateWidget(old);
    if (_lastValue != null && widget.value > _lastValue!) {
      _firePulse();
    }
    _lastValue = widget.value;
  }

  @override
  void initState() {
    super.initState();
    _lastValue = widget.value;
  }

  void _firePulse() {
    setState(() => _pulsing = true);
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _pulsing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pulsing ? 1.25 : 1.0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: _pulsing
              ? [BoxShadow(color: widget.glowColor.withOpacity(0.55), blurRadius: 14, spreadRadius: 2)]
              : const [],
        ),
        child: widget.child,
      ),
    );
  }
}
PATCH_EOF

mkdir -p "lib/shared/widgets"
cat > "lib/shared/widgets/achievement_toast.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';

/// A small, self-dismissing confirmation pill — "Streak continued",
/// "+10 Focus" — per the brief's "micro-achievement" spec: fade+slide
/// in, hold, fade+slide out, no modal, no celebration screen. Callers
/// control *when* it shows by changing [message] from null to a string;
/// this widget owns only the appear/hold/disappear animation.
class AchievementToast extends StatefulWidget {
  const AchievementToast({super.key, required this.message, required this.accentColor});

  final String? message;
  final Color accentColor;

  @override
  State<AchievementToast> createState() => _AchievementToastState();
}

class _AchievementToastState extends State<AchievementToast> {
  String? _displayed;

  @override
  void didUpdateWidget(AchievementToast old) {
    super.didUpdateWidget(old);
    if (widget.message != null && widget.message != old.message) {
      setState(() => _displayed = widget.message);
      Future.delayed(const Duration(milliseconds: 1600), () {
        if (mounted && _displayed == widget.message) setState(() => _displayed = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedSlide(
        offset: _displayed == null ? const Offset(0, -0.4) : Offset.zero,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: _displayed == null ? 0 : 1,
          duration: const Duration(milliseconds: 220),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1D25),
              borderRadius: BorderRadius.circular(100),
              border: Border.all(color: widget.accentColor.withOpacity(0.4)),
              boxShadow: [BoxShadow(color: widget.accentColor.withOpacity(0.25), blurRadius: 16)],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt_rounded, size: 13, color: widget.accentColor),
                const SizedBox(width: 6),
                Text(
                  _displayed ?? '',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: widget.accentColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
PATCH_EOF

git add -A
git -c user.email="dev@ulimit.app" -c user.name="Ulimit Dev" commit -m "Home screen: lime/red gamification layer -- gradient, rolling numbers, real week-over-week deltas, streak pulse, achievement toast, swipe tabs"
git push

echo "Pushed. Removing this script."
rm -- "$0"
