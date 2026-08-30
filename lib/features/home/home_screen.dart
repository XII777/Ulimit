import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/restriction_engine.dart';
import '../../core/icons/app_icons.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/premium_components.dart';
import '../../data/apps_repository.dart';
import '../../shared/widgets/spring_scroll.dart';
import '../../data/db/app_database.dart';
import '../../data/focus_providers.dart';
import '../../data/home_data_providers.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../shared/widgets/app_selector.dart';
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
    final focusSession = ref.watch(activeFocusSessionProvider).valueOrNull;
    final decisions = ref.watch(restrictionDecisionsProvider);
    final activeBlocks =
        decisions.values.where((d) => d.appBlocked).length;
    final bedtime = ref.watch(bedtimeScheduleProvider).valueOrNull;

    return ListView(
        physics: springScrollPhysics,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
        children: [
          const _Header(),
          const SizedBox(height: 22),

          Center(child: _buildRing(screenTime, budgetMinutes)),
          const SizedBox(height: 28),

          if (focusSession != null) ...[
            const PremiumSectionLabel('CURRENT FOCUS'),
            const SizedBox(height: 10),
            _CurrentFocusCard(session: focusSession),
            const SizedBox(height: 28),
          ],

          if (activeBlocks > 0) ...[
            PremiumSectionLabel('RESTRICTIONS · $activeBlocks ACTIVE'),
            const SizedBox(height: 10),
            _ActiveRestrictions(decisions: decisions),
            const SizedBox(height: 28),
          ],

          if (bedtime != null && bedtime.enabled) ...[
            const PremiumSectionLabel('TONIGHT'),
            const SizedBox(height: 10),
            _BedtimeCard(bedtime: bedtime),
            const SizedBox(height: 28),
          ],

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
                  values: [
                    for (final v in weeklyPickups.valueOrNull ?? const <int>[]) v.toDouble()
                  ],
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
    );
  }

  Widget _buildRing(AsyncValue<Duration> screenTime, AsyncValue<int> budgetMinutes) {
    if (screenTime.isLoading || budgetMinutes.isLoading) {
      return LimitRing(progress: 0, size: 130, trackColor: AppColors.stroke);
    }
    final used = screenTime.valueOrNull ?? Duration.zero;
    final budget = Duration(minutes: budgetMinutes.valueOrNull ?? 240);
    return _ScreenTimeRing(used: used, budget: budget);
  }

  String _formatFocusTotal(int? seconds) {
    if (seconds == null || seconds == 0) return '0m';
    return formatDurationShort(Duration(seconds: seconds));
  }

  String _formatPickupsAvg(List<int>? days) {
    if (days == null || days.isEmpty) return '—';
    final avg = days.reduce((a, b) => a + b) / days.length;
    return avg.round().toString();
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(greeting,
            style: TextStyle(
                fontSize: 26, fontWeight: FontWeight.w600, color: AppColors.ink, letterSpacing: -0.3)),
        const SizedBox(height: 2),
        Text(_formattedDate(), style: TextStyle(fontSize: AppText.body, color: AppColors.inkDim)),
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
              text: formatDurationShort(remaining),
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600, color: AppColors.ink),
            ),
            const SizedBox(height: 4),
            Text('LEFT TODAY',
                style: TextStyle(
                    fontSize: AppText.overline, color: AppColors.inkFaint, letterSpacing: 0.6)),
          ],
        ),
      ),
    );
  }
}

/// Live "current focus" summary — remaining time reads from the same
/// timestamp the enforcement layer uses, so what the user sees and
/// what the phone does can't diverge.
class _CurrentFocusCard extends ConsumerWidget {
  const _CurrentFocusCard({required this.session});
  final FocusSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = ref.watch(focusRemainingProvider).valueOrNull ?? Duration.zero;
    final plannedEnd = session.startedAt.add(Duration(seconds: session.plannedSeconds));
    final endsAt = TimeOfDay.fromDateTime(plannedEnd).format(context);

    return PremiumCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: AppIcon(AppIconName.stopwatch, size: 18, color: AppColors.ink),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(session.label,
                    style: TextStyle(
                        fontSize: AppText.title, fontWeight: FontWeight.w600, color: AppColors.ink)),
                const SizedBox(height: 2),
                Text('Ends at $endsAt',
                    style: TextStyle(fontSize: AppText.caption, color: AppColors.inkDim)),
              ],
            ),
          ),
          Text(
            formatClock(remaining),
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.ink),
          ),
          const SizedBox(width: 8),
          AppIcon(AppIconName.chevronRight, size: 14, color: AppColors.inkFaint),
        ],
      ),
    );
  }
}

/// Compact list of what's actually blocked right now, with the honest
/// "until" from the engine (null → permanent).
class _ActiveRestrictions extends ConsumerWidget {
  const _ActiveRestrictions({required this.decisions});
  final Map<String, AppDecision> decisions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(appsCatalogProvider);
    final blocked = decisions.entries.where((e) => e.value.appBlocked).toList()
      ..sort((a, b) {
        final au = a.value.until;
        final bu = b.value.until;
        if (au == null && bu == null) return 0;
        if (au == null) return -1;
        if (bu == null) return 1;
        return au.compareTo(bu);
      });
    final shown = blocked.take(4);

    return Column(
      children: [
        for (final entry in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _RestrictionLine(
              packageName: entry.key,
              appName: catalog.valueOrNull?.nameFor(entry.key) ?? entry.key,
              decision: entry.value,
            ),
          ),
      ],
    );
  }
}

class _RestrictionLine extends StatelessWidget {
  const _RestrictionLine({
    required this.packageName,
    required this.appName,
    required this.decision,
  });

  final String packageName;
  final String appName;
  final AppDecision decision;

  @override
  Widget build(BuildContext context) {
    final until = decision.until;
    final untilText = until == null
        ? 'Blocked until removed'
        : 'Blocked until ${TimeOfDay.fromDateTime(until).format(context)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          AppIconView(packageName: packageName),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(appName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: AppText.body, color: AppColors.ink)),
                Text(untilText,
                    style: TextStyle(fontSize: 11, color: AppColors.inkDim)),
              ],
            ),
          ),
          Text(
            decision.reason?.label ?? '',
            style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint),
          ),
        ],
      ),
    );
  }
}

class _BedtimeCard extends StatelessWidget {
  const _BedtimeCard({required this.bedtime});
  final BedtimeScheduleData bedtime;

  @override
  Widget build(BuildContext context) {
    return PremiumCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: AppIcon(AppIconName.moon, size: 18, color: AppColors.ink),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bedtime',
                    style: TextStyle(
                        fontSize: AppText.title, fontWeight: FontWeight.w600, color: AppColors.ink)),
                const SizedBox(height: 2),
                Text(
                  '${_fmt(context, bedtime.startTime)} — ${_fmt(context, bedtime.endTime)}'
                  '${bedtime.dndEnabled ? ' · DND' : ''}',
                  style: TextStyle(fontSize: AppText.caption, color: AppColors.inkDim),
                ),
              ],
            ),
          ),
          AppIcon(AppIconName.chevronRight, size: 14, color: AppColors.inkFaint),
        ],
      ),
    );
  }

  String _fmt(BuildContext context, String hhmm) => TimeOfDay.fromDateTime(
        DateTime(2026, 1, 1, int.parse(hhmm.split(':')[0]), int.parse(hhmm.split(':')[1])),
      ).format(context);
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
              Text('Avg. daily screen time',
                  style: TextStyle(
                      fontSize: AppText.caption, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
              if (delta.hasData) _DeltaLabel(delta: delta),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hasData ? _formatHours(avg) : 'No data yet',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.ink),
          ),
          const SizedBox(height: 8),
          if (hasData)
            TrendAreaChart(values: values, color: AppColors.ink, showAverageLine: false)
          else
            SizedBox(
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
    return formatDurationShort(Duration(minutes: (hours * 60).round()));
  }
}

class _DeltaLabel extends StatelessWidget {
  const _DeltaLabel({required this.delta});
  final TrendDelta delta;

  @override
  Widget build(BuildContext context) {
    final arrow = delta.isPositive ? '▲' : '▼';
    return Text(
      '$arrow ${delta.percent.round()}%',
      style: TextStyle(
          fontSize: AppText.caption, color: AppColors.inkDim, fontWeight: FontWeight.w600),
    );
  }
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(fontSize: 9, color: AppColors.inkFaint));
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
          Text(label,
              style: TextStyle(
                  fontSize: 11.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Sparkline(values: values, color: AppColors.ink),
          const SizedBox(height: 6),
          RollingNumber(
            text: valueText,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.ink),
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

class _ControlsList extends StatelessWidget {
  const _ControlsList();

  static const _tiles = <(String, AppIconName, String, String?)>[
    ('Focus', AppIconName.stopwatch, 'Start a session', Routes.focus),
    ('App Limits', AppIconName.limits, 'Per-app limits & groups', Routes.limits),
    ('App Blocking', AppIconName.block, 'Temporary & permanent blocks', Routes.restrictions),
    ('Internet & Sites', AppIconName.internet, 'VPN, internet blocks & filters', Routes.internet),
    ('Notifications', AppIconName.notifications, 'Pause, hold & DND access', Routes.notifications),
    ('Bedtime', AppIconName.bedtime, 'Manage schedule', Routes.bedtime),
    ('Parental & Lock', AppIconName.shieldLock, 'Device admin & tamper protection', Routes.parental),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final (title, icon, description, route) in _tiles) ...[
          PremiumFeatureTile(
            icon: AppIcon(icon, size: 18, color: AppColors.ink),
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
