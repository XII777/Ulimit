import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rolling_text/rolling_text.dart';

import '../../core/engine/restriction_engine.dart';
import '../../core/icons/app_icons.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/premium_components.dart';
import '../../data/apps_repository.dart';
import '../../data/focus_providers.dart';
import '../../data/home_data_providers.dart';
import '../../data/permissions_providers.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../shared/widgets/app_selector.dart';
import '../../shared/widgets/counter_roll.dart' show kCounterRollOptions, kCounterRollSpacing;
import '../../shared/widgets/pressable_scale.dart';
import '../../shared/widgets/spring_scroll.dart';
import '../../shared/widgets/trend_chart.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weeklyFocusSeconds = ref.watch(weeklyFocusSecondsProvider);
    final weeklyFocusHours = ref.watch(weeklyFocusHoursByDayProvider);
    final weeklyPickups = ref.watch(weeklyPickupsProvider);
    final focusDelta = ref.watch(focusTimeDeltaProvider);
    final pickupsDelta = ref.watch(pickupsDeltaProvider);
    final decisions = ref.watch(restrictionDecisionsProvider);
    final activeBlocks = decisions.values.where((d) => d.appBlocked).length;

    return ListView(
      physics: springScrollPhysics,
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, ref.watch(hideNavBarProvider).valueOrNull == true ? navBarHiddenInset : navBarPillInset),
      children: [
         _Header(),
        const SizedBox(height: 22),

        Row(
          children: [
            Expanded(child: _ScreenTimeCard()),
            const SizedBox(width: 10),
            Expanded(child: _FocusTimeCard()),
          ],
        ),
        const SizedBox(height: 28),

        if (activeBlocks > 0) ...[
          PremiumSectionLabel('RESTRICTIONS · $activeBlocks ACTIVE'),
          const SizedBox(height: 10),
          _ActiveRestrictions(decisions: decisions),
          const SizedBox(height: 28),
        ],

         PremiumSectionLabel('WEEKLY OVERVIEW'),
        const SizedBox(height: 10),
        _WeeklyTrendCard(
          onTap: () => context.push(Routes.screenTime),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _MiniTrendCard(
                label: 'Focus Time',
                valueText: _formatFocusAvg(weeklyFocusSeconds.valueOrNull),
                values: weeklyFocusHours.valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0],
                delta: focusDelta,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _MiniTrendCard(
                label: 'Pickups / Day',
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

         PremiumSectionLabel('CONTROLS'),
        const SizedBox(height: 10),
         _ControlsList(),
      ],
    );
  }

  String _formatFocusAvg(int? seconds) {
    if (seconds == null || seconds == 0) return '0m';
    // Weekly average: total ÷ 7 days (matching the "Avg. daily" card).
    final avgSeconds = (seconds / 7).round();
    return formatDurationHMS(Duration(seconds: avgSeconds));
  }

  String _formatPickupsAvg(List<int>? days) {
    if (days == null || days.isEmpty) return '—';
    final avg = days.reduce((a, b) => a + b) / days.length;
    return avg.round().toString();
  }
}

class _Header extends StatelessWidget {
   _Header();

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

/// Live today screen time: persisted total + the running app's
/// un-attributed elapsed time, ticking once per second. Only this card
/// rebuilds on the tick — the rest of Home is untouched.
class _ScreenTimeCard extends ConsumerWidget {
   _ScreenTimeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seconds = ref.watch(liveScreenTimeSecondsProvider).valueOrNull ?? 0;
    final budget = ref.watch(dailyBudgetProvider).valueOrNull ?? 240;
    final ratio = budget > 0 ? (seconds / (budget * 60)).clamp(0.0, 1.0) : 0.0;

    return RepaintBoundary(child: PremiumCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(AppIconName.phone, size: 13, color: AppColors.inkDim),
              const SizedBox(width: 6),
              Text('Screen Time',
                  style: TextStyle(fontSize: 11.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: RollingText(
              text: formatDurationHMS(Duration(seconds: seconds)),
                spacing: kCounterRollSpacing,
              options: kCounterRollOptions,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.ink,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 4,
              backgroundColor: AppColors.stroke,
              valueColor: AlwaysStoppedAnimation(AppColors.ink),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'of $budget min today',
            style: TextStyle(fontSize: 10, color: AppColors.inkFaint),
          ),
        ],
      ),
      ),
    );
  }
}

/// Live accumulated Focus time for today; tapping opens the date-wise
/// Focus history page.
class _FocusTimeCard extends ConsumerWidget {
   _FocusTimeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seconds = ref.watch(liveFocusSecondsTodayProvider).valueOrNull ?? 0;

    return RepaintBoundary(child: PressableScale(
      onTap: () => context.push('/focus-history'),
      child: PremiumCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIcon(AppIconName.stopwatch, size: 13, color: AppColors.inkDim),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Focus Time',
                      style: TextStyle(
                          fontSize: 11.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
                ),
                AppIcon(AppIconName.chevronRight, size: 12, color: AppColors.inkFaint),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: RollingText(
                text: formatDurationHMS(Duration(seconds: seconds)),
              spacing: kCounterRollSpacing,
                options: kCounterRollOptions,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'today · tap for history',
              style: TextStyle(fontSize: 10, color: AppColors.inkFaint),
            ),
          ],
        ),
        ),
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
                Text(untilText, style: TextStyle(fontSize: 11, color: AppColors.inkDim)),
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

class _WeeklyTrendCard extends ConsumerWidget {
  const _WeeklyTrendCard({
    this.onTap,
  });

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // TODAY's screen time (live): DB total + pending foreground window,
    // plus the today's hourly buckets drawn as a LINE graph (not bars).
    final todaySeconds = ref.watch(liveScreenTimeSecondsProvider).valueOrNull ?? 0;
    final hourly = ref.watch(deviceHourlyUsageProvider).valueOrNull ?? const <int>[];
    // The TrendAreaChart wants a series — feed it today's cumulative
    // hourly values so the line rises through the day, peaking at the
    // latest usage (0 → today's total).
    final cumulative = <double>[];
    var run = 0;
    for (final h in hourly) {
      run += h;
      cumulative.add(run.toDouble());
    }
    final hasData = todaySeconds > 0 && cumulative.any((v) => v > 0);
    // Gate text reflects the actual state: data present → chart; no
    // data but tracking on → "will appear as you use the phone";
    // tracking off → the enable prompt.
    final accessibilityOn =
        ref.watch(accessibilityEnabledProvider).valueOrNull ?? false;
    final usageOn = ref.watch(usageAccessGrantedProvider).valueOrNull ?? false;

    return RepaintBoundary(child: PressableScale(
      onTap: onTap,
      child: PremiumCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Screen time today',
                  style: TextStyle(
                      fontSize: AppText.caption, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
              if (hasData) Text('Live',
                  style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint)),
            ],
          ),
          const SizedBox(height: 4),
          RollingText(
            text: hasData || todaySeconds > 0
                ? formatDurationHMS(Duration(seconds: todaySeconds))
                : 'No data yet',
            spacing: kCounterRollSpacing,
            options: kCounterRollOptions,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.ink),
          ),
          const SizedBox(height: 8),
          if (hasData)
            TrendAreaChart(
                values: cumulative, color: AppColors.ink, showAverageLine: false, height: 84)
          else
            SizedBox(
              height: 84,
              child: Center(
                child: Text(
                  (accessibilityOn || usageOn)
                      ? 'Charts appear as your usage builds up'
                      : 'Enable Accessibility access to start tracking',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: AppText.caption, color: AppColors.inkFaint),
                ),
              ),
            ),
          const SizedBox(height: 4),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _DayLabel('12 AM'), _DayLabel('4 AM'), _DayLabel('8 AM'), _DayLabel('12 PM'),
              _DayLabel('4 PM'), _DayLabel('8 PM'), _DayLabel('12 AM'),
            ],
          ),
        ],
        ),
      ),
    ));
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
    return RepaintBoundary(child: PremiumCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Sparkline(values: values, color: AppColors.ink),
          const SizedBox(height: 6),
          RollingText(
            text: valueText,
            spacing: kCounterRollSpacing,
            options: kCounterRollOptions,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.ink),
          ),
          if (delta.hasData) ...[
            const SizedBox(height: 2),
            _DeltaLabel(delta: delta),
          ],
        ],
        ),
      ),
    );
  }
}

class _ControlsList extends StatelessWidget {
   _ControlsList();

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
