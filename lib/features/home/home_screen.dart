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
