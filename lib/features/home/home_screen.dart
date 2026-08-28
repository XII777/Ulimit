import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/providers.dart';
import '../../shared/widgets/limit_ring.dart';
import '../../shared/widgets/mini_charts.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenTime = ref.watch(todayScreenTimeProvider);
    final scoreState = ref.watch(limitScoreProvider);
    final todaysSessions = ref.watch(todaysCompletedSessionsProvider);

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topCenter,
          radius: 1.1,
          colors: [Color(0x3A8B7FE8), Colors.transparent],
          stops: [0.0, 0.6],
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
          children: [
            Text('Today', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 2),
            Text(_formattedDate(), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),

            scoreState.when(
              data: (s) => _LimitScoreBanner(score: s.score, tier: s.tier, toNextBadge: s.pointsToNextTier),
              loading: () => const _LimitScoreBanner(score: 0, tier: '—', toNextBadge: 0),
              error: (_, __) => const _LimitScoreBanner(score: 0, tier: '—', toNextBadge: 0),
            ),
            const SizedBox(height: 16),

            Center(
              child: screenTime.when(
                data: (used) => _ScreenTimeRing(used: used, budget: const Duration(hours: 4)),
                // Skeleton state instead of a spinner — a spinner would
                // be the only moving thing on a static-looking screen
                // and reads as slower than it is.
                loading: () => const LimitRing(
                  progress: 0,
                  size: 118,
                  trackColor: AppColors.stroke,
                ),
                error: (_, __) => const Icon(Icons.error_outline, color: AppColors.danger),
              ),
            ),
            const SizedBox(height: 14),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                scoreState.when(
                  data: (s) => _StatPill(
                    icon: Icons.local_fire_department_rounded,
                    label: '${s.streakDays} day streak',
                  ),
                  loading: () => const _StatPill(icon: Icons.local_fire_department_rounded, label: '—'),
                  error: (_, __) => const _StatPill(icon: Icons.local_fire_department_rounded, label: '—'),
                ),
                const SizedBox(width: 8),
                todaysSessions.when(
                  data: (n) => _StatPill(
                    icon: Icons.timer_outlined,
                    label: '$n session${n == 1 ? '' : 's'}',
                  ),
                  loading: () => const _StatPill(icon: Icons.timer_outlined, label: '—'),
                  error: (_, __) => const _StatPill(icon: Icons.timer_outlined, label: '—'),
                ),
              ],
            ),
            const SizedBox(height: 24),

            Text('THIS WEEK', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            const _WeeklyScreenTimeCard(),
            const SizedBox(height: 10),
            const _WeeklyFocusTimeCard(),
            const SizedBox(height: 24),

            Text('CONTROLS', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            const _ControlsGrid(),
          ],
        ),
      ),
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

class _ScreenTimeRing extends StatelessWidget {
  const _ScreenTimeRing({required this.used, required this.budget});
  final Duration used;
  final Duration budget;

  @override
  Widget build(BuildContext context) {
    final remaining = budget - used;
    final progress = 1 - (used.inSeconds / budget.inSeconds).clamp(0.0, 1.0);

    // Ring color IS the state signal (design system: calm = on track,
    // alert = near limit) — not decoration, so it's derived from
    // progress rather than a fixed color.
    final ringColor = progress <= 0.15 ? AppColors.alert : AppColors.calm;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: progress),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => LimitRing(
        progress: value,
        size: 118,
        strokeWidth: 8,
        color: ringColor,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_formatDuration(remaining), style: Theme.of(context).textTheme.headlineSmall),
            Text('LEFT TODAY', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.inkDim),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5)),
        ],
      ),
    );
  }
}

class _LimitScoreBanner extends StatelessWidget {
  const _LimitScoreBanner({required this.score, required this.tier, required this.toNextBadge});
  final int score;
  final String tier;
  final int toNextBadge;

  @override
  Widget build(BuildContext context) {
    final subtitle = toNextBadge > 0 ? '$tier tier · $toNextBadge to next tier' : '$tier tier · top tier';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [AppColors.accent, AppColors.accentSoft, AppColors.accent],
                ),
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
                      Text('$score', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 6),
                      Text('Limit', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
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

/// Percent change helper shared by the two weekly cards below — kept in
/// one place so "how we compute a delta" has one definition, not two
/// slightly-different ones.
String _deltaLabel(int thisWeekAvgSeconds, int lastWeekAvgSeconds) {
  if (lastWeekAvgSeconds <= 0) return 'No data last week';
  final change = ((thisWeekAvgSeconds - lastWeekAvgSeconds) / lastWeekAvgSeconds) * 100;
  final arrow = change <= 0 ? '▼' : '▲';
  return '$arrow ${change.abs().round()}% vs last week';
}

class _WeeklyScreenTimeCard extends ConsumerWidget {
  const _WeeklyScreenTimeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weekly = ref.watch(weeklyScreenTimeProvider);
    final previous = ref.watch(previousWeekScreenTimeAvgProvider);

    return weekly.when(
      data: (days) => previous.when(
        data: (prevAvg) => _buildCard(context, days, prevAvg.inSeconds),
        loading: () => _buildCard(context, days, null),
        error: (_, __) => _buildCard(context, days, null),
      ),
      loading: () => const SizedBox(height: 140),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildCard(BuildContext context, List<Duration> days, int? prevAvgSeconds) {
    final seconds = days.map((d) => d.inSeconds).toList();
    final avgSeconds = seconds.isEmpty ? 0 : seconds.reduce((a, b) => a + b) ~/ seconds.length;
    final values = seconds.map((s) => s / 3600).toList(); // hours, for the chart
    final avgHours = avgSeconds / 3600;

    // Decreasing screen time is the "good" direction for this metric —
    // colors the delta accordingly, unlike focus time below where more
    // is good.
    final isGood = prevAvgSeconds == null || avgSeconds <= prevAvgSeconds;

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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Screen time', style: Theme.of(context).textTheme.bodySmall),
              Text(
                prevAvgSeconds == null ? '' : _deltaLabel(avgSeconds, prevAvgSeconds),
                style: TextStyle(
                  fontSize: 10,
                  color: isGood ? AppColors.calm : AppColors.alert,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(_formatHours(avgSeconds), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 22, fontWeight: FontWeight.w700)),
          Text('daily average', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10.5)),
          const SizedBox(height: 10),
          WeeklyAreaChart(values: values, average: avgHours),
          const SizedBox(height: 6),
          _DayLabelsRow(days: _lastNDays(7)),
        ],
      ),
    );
  }

  String _formatHours(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _WeeklyFocusTimeCard extends ConsumerWidget {
  const _WeeklyFocusTimeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weekly = ref.watch(weeklyFocusTimeProvider);
    final previous = ref.watch(previousWeekFocusTimeAvgProvider);

    return weekly.when(
      data: (days) => previous.when(
        data: (prevAvg) => _buildCard(context, days, prevAvg.inSeconds),
        loading: () => _buildCard(context, days, null),
        error: (_, __) => _buildCard(context, days, null),
      ),
      loading: () => const SizedBox(height: 100),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildCard(BuildContext context, List<Duration> days, int? prevAvgSeconds) {
    final seconds = days.map((d) => d.inSeconds).toList();
    final totalSeconds = seconds.fold(0, (a, b) => a + b);
    final avgSeconds = seconds.isEmpty ? 0 : totalSeconds ~/ seconds.length;
    final values = seconds.map((s) => s / 3600).toList();

    // More focus time is the "good" direction here — opposite of the
    // screen-time card above.
    final isGood = prevAvgSeconds == null || avgSeconds >= prevAvgSeconds;

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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Focus time', style: Theme.of(context).textTheme.bodySmall),
              Text(
                prevAvgSeconds == null ? '' : _deltaLabel(avgSeconds, prevAvgSeconds),
                style: TextStyle(
                  fontSize: 10,
                  color: isGood ? AppColors.calm : AppColors.alert,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(_formatHours(totalSeconds), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w700)),
          Text('this week', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10.5)),
          const SizedBox(height: 8),
          MiniTrendLine(values: values, color: AppColors.calm, height: 32),
        ],
      ),
    );
  }

  String _formatHours(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

List<DateTime> _lastNDays(int n) {
  final today = DateTime.now();
  final start = DateTime(today.year, today.month, today.day).subtract(Duration(days: n - 1));
  return [for (var i = 0; i < n; i++) start.add(Duration(days: i))];
}

class _DayLabelsRow extends StatelessWidget {
  const _DayLabelsRow({required this.days});
  final List<DateTime> days;

  static const _letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final d in days)
          Text(_letters[d.weekday - 1], style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10)),
      ],
    );
  }
}

class _ControlsGrid extends ConsumerWidget {
  const _ControlsGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(restrictionGroupsProvider);
    final blockedCount = ref.watch(blockedAppsCountProvider);

    final limitsSubtitle = groups.when(
      data: (gs) {
        final nearLimit = gs.where((g) => g.limitSeconds > 0 && g.usedSeconds / g.limitSeconds >= 0.66).length;
        return '${gs.length} groups · $nearLimit near limit';
      },
      loading: () => '—',
      error: (_, __) => '—',
    );

    final blockingSubtitle = blockedCount.when(
      data: (n) => '$n apps blocked',
      loading: () => '—',
      error: (_, __) => '—',
    );

    // Internet & Sites and Notifications have no backing table yet (no
    // VPN/DNS state, no notification-batching settings) — left as
    // clearly-labeled placeholders rather than fabricating numbers.
    final tiles = [
      (
        'Focus', Icons.track_changes_rounded, 'Tap to start a session',
        AppColors.accent, AppColors.accent,
      ),
      (
        'App Limits', Icons.grid_view_rounded, limitsSubtitle,
        AppColors.alert, AppColors.alert,
      ),
      (
        'App Blocking', Icons.block_rounded, blockingSubtitle,
        AppColors.danger, AppColors.inkFaint,
      ),
      (
        'Internet & Sites', Icons.public_rounded, 'Not configured yet',
        AppColors.calm, AppColors.calm,
      ),
      (
        'Notifications', Icons.notifications_rounded, 'Not configured yet',
        AppColors.accentSoft, null,
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: tiles.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 9,
        crossAxisSpacing: 9,
        childAspectRatio: 1.5,
      ),
      itemBuilder: (context, i) {
        final (title, icon, subtitle, iconColor, statusColor) = tiles[i];
        return _ControlTile(
          title: title,
          icon: icon,
          subtitle: subtitle,
          iconColor: iconColor,
          statusColor: statusColor,
        );
      },
    );
  }
}

class _ControlTile extends StatelessWidget {
  const _ControlTile({
    required this.title,
    required this.icon,
    required this.subtitle,
    required this.iconColor,
    required this.statusColor,
  });

  final String title;
  final IconData icon;
  final String subtitle;
  final Color iconColor;

  /// Null hides the status dot entirely — not every control has a live
  /// "state" to show (Notifications doesn't, in the design).
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () {}, // wire to detail routes
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.stroke),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: iconColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(icon, size: 15, color: iconColor),
                  ),
                  if (statusColor != null)
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                    ),
                ],
              ),
              Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 12.5)),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
