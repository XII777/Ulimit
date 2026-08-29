import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/premium_components.dart';
import '../../data/providers.dart';
import '../../data/home_data_providers.dart';
import '../../shared/widgets/limit_ring.dart';
import '../../shared/widgets/trend_chart.dart';
import '../../shared/widgets/rolling_number.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenTime = ref.watch(todayScreenTimeProvider);
    final budgetMinutes = ref.watch(dailyBudgetProvider);
    final weeklyUsage = ref.watch(weeklyScreenTimeHoursProvider);
    final weeklyFocusSeconds = ref.watch(weeklyFocusSecondsProvider);
    final weeklyFocusHours = ref.watch(weeklyFocusHoursByDayProvider);
    final weeklyPickups = ref.watch(weeklyPickupsProvider);
    final screenTimeDelta = ref.watch(screenTimeDeltaProvider);
    final focusDelta = ref.watch(focusTimeDeltaProvider);
    final pickupsDelta = ref.watch(pickupsDeltaProvider);

    return DecoratedBox(
      // A very faint white top vignette for depth — not a colored
      // "atmospheric" gradient. Alpha stays low enough that the top
      // and bottom of the screen read as the same near-black surface;
      // this is lighting, not an accent.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, 0.35],
          colors: [Color(0x14FFFFFF), Colors.transparent],
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
          children: [
            const _Header(),
            const SizedBox(height: 22),

            Center(
              child: _buildRing(screenTime, budgetMinutes),
            ),
            const SizedBox(height: 28),

            const PremiumSectionLabel('THIS WEEK'),
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

            const PremiumSectionLabel('CONTROLS'),
            const SizedBox(height: 10),
            const _ControlsList(),
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
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Today',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: AppColors.ink)),
        const SizedBox(height: 2),
        Text(_formattedDate(), style: const TextStyle(fontSize: AppText.body, color: AppColors.inkDim)),
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
      builder: (context, value, _) => LimitRing(
        progress: value,
        size: 148,
        strokeWidth: 8,
        color: AppColors.ink,
        trackColor: AppColors.stroke,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RollingNumber(
              text: _formatDuration(remaining),
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w600, color: AppColors.ink),
            ),
            const SizedBox(height: 4),
            const Text('LEFT TODAY',
                style: TextStyle(fontSize: AppText.overline, color: AppColors.inkFaint, letterSpacing: 0.6)),
          ],
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

class _WeeklyTrendCard extends StatelessWidget {
  const _WeeklyTrendCard({required this.weeklyHours, required this.delta});
  final AsyncValue<List<double>> weeklyHours;
  final TrendDelta delta;

  @override
  Widget build(BuildContext context) {
    final values = weeklyHours.valueOrNull;
    final hasData = values != null && values.any((v) => v > 0);
    final avg = hasData ? values.reduce((a, b) => a + b) / values.length : 0.0;

    return PremiumCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Avg. daily screen time',
                  style: TextStyle(fontSize: AppText.caption, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
              if (delta.hasData) _DeltaLabel(delta: delta),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hasData ? _formatHours(avg) : 'No data yet',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.ink),
          ),
          const SizedBox(height: 8),
          if (hasData)
            TrendAreaChart(values: values, color: AppColors.ink, showAverageLine: false)
          else
            const SizedBox(
              height: 84,
              child: Center(
                child: Text(
                  'Enable Accessibility access to start tracking',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: AppText.caption, color: AppColors.inkFaint),
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

/// Factual trend indicator — arrow + percentage, always rendered in
/// [AppColors.ink]. Direction is carried by the arrow glyph and the
/// adjacent label's wording ("vs last week"), not by color, per the
/// design system's monochrome rule and its own accessibility principle
/// that meaning must never rest on color alone.
class _DeltaLabel extends StatelessWidget {
  const _DeltaLabel({required this.delta});
  final TrendDelta delta;

  @override
  Widget build(BuildContext context) {
    final arrow = delta.isPositive ? '▲' : '▼';
    return Text(
      '$arrow ${delta.percent.round()}%',
      style: const TextStyle(fontSize: AppText.caption, color: AppColors.inkDim, fontWeight: FontWeight.w600),
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
    return PremiumCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Sparkline(values: values, color: AppColors.ink),
          const SizedBox(height: 6),
          RollingNumber(
            text: valueText,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.ink),
          ),
          if (delta.hasData) ...[
            const SizedBox(height: 2),
            _DeltaLabel(delta: delta),
          ],
        ],
      ),
    );
  }
}

/// Full-width horizontal tiles per the design system's feature-navigation
/// pattern — replaces the previous 2-column icon-grid layout, which was
/// a different visual language from every other feature-nav surface in
/// the app.
class _ControlsList extends StatelessWidget {
  const _ControlsList();

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
    return Column(
      children: [
        for (final (title, icon, description, route) in _tiles) ...[
          PremiumFeatureTile(
            icon: icon,
            title: title,
            description: description,
            onTap: route == null ? null : () => context.push(route),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
