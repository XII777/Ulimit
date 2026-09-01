import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/icons/app_icons.dart';
import '../../core/engine/restriction_engine.dart' show formatDurationHMS;
import '../../core/router/app_router.dart';
import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/apps_repository.dart';
import '../../data/home_data_providers.dart';
import '../../data/providers.dart';
import '../../shared/widgets/spring_scroll.dart';
import '../../shared/widgets/trend_chart.dart';

/// Screen Time detail page. Top: the weekly trend graph (same shape as
/// Home's Avg. daily card). Below: every tracked app's usage for the
/// selected window (Last 7 days, or Today) with its daily total.
class ScreenTimeScreen extends ConsumerStatefulWidget {
  const ScreenTimeScreen({super.key});

  @override
  ConsumerState<ScreenTimeScreen> createState() => _ScreenTimeScreenState();
}

class _ScreenTimeScreenState extends ConsumerState<ScreenTimeScreen> {
  // false = last 7 days, true = today.
  bool _todayOnly = false;

  @override
  Widget build(BuildContext context) {
    final weekly = ref.watch(weeklyScreenTimeProvider);
    final weeklyHours = ref.watch(weeklyScreenTimeHoursProvider).valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0];

    // The window runs [today-6 … today]: the LAST column is always the
    // present day, so the labels must reflect the actual dates.
    final today = DateTime.now();
    final windowStart = DateTime(today.year, today.month, today.day).subtract(const Duration(days: 6));
    final dayLabels = List.generate(7, (i) {
      final d = windowStart.add(Duration(days: i));
      // Sunday → 'S', Monday → 'M' … single-letter, derived from the
      // real weekday so the label track follows the data automatically.
      const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
      return letters[d.weekday - 1];
    });

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.ink,
        title: Text('Screen Time', style: Theme.of(context).textTheme.titleMedium),
      ),
      body: ListView(
        physics: springScrollPhysics,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
        children: [
          // Filter chips: Today | Last 7 days
          Row(
            children: [
              _FilterChip(
                label: 'Today',
                selected: _todayOnly,
                onTap: () => setState(() => _todayOnly = true),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: 'Last 7 days',
                selected: !_todayOnly,
                onTap: () => setState(() => _todayOnly = false),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Top card mirrors the filter: Today → today's total + hour
          // bars; Last 7 days → the weekly trend + dynamic day labels.
          _todayOnly
              ? _TodayPanel()
              : PremiumCard(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('7-day screen time',
                          style: TextStyle(
                              fontSize: AppText.caption,
                              color: AppColors.inkDim,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(
                        _weeklyTotalLabel(weekly.valueOrNull),
                        style:
                            TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.ink),
                      ),
                      const SizedBox(height: 8),
                      TrendAreaChart(
                          values: weeklyHours, color: AppColors.ink, showAverageLine: true),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (final l in dayLabels) _DayLabel(l),
                        ],
                      ),
                    ],
                  ),
                ),
          const SizedBox(height: 18),

          // Per-app usage list for the selected window
          _AppUsageList(todayOnly: _todayOnly),
        ],
      ),
    );
  }

  String _weeklyTotalLabel(List<Duration>? days) {
    if (days == null || days.isEmpty || !days.any((d) => d.inSeconds > 0)) return 'No data yet';
    final total = days.fold<Duration>(Duration.zero, (sum, d) => sum + d);
    return '${total.inHours}h ${total.inMinutes % 60}m this week';
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: selected ? null : Border.all(color: AppColors.stroke),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.bg : AppColors.inkDim,
          ),
        ),
      ),
    );
  }
}

/// Every tracked app's usage for the selected window, sorted by time.
class _AppUsageList extends ConsumerWidget {
  const _AppUsageList({required this.todayOnly});

  final bool todayOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(todayOnly ? todayUsageByPackageProvider : windowUsageByPackageProvider);
    final appMap = usage.valueOrNull ?? const <String, int>{};
    final catalog = ref.watch(appsCatalogProvider).valueOrNull;

    final entries = appMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Text(
          'No usage in this window yet.\nEnable Accessibility / Usage access to start tracking.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppColors.inkFaint, height: 1.5),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('APPS',
            style: TextStyle(
                fontSize: AppText.overline, color: AppColors.inkFaint, letterSpacing: 0.6)),
        const SizedBox(height: 8),
        for (final entry in entries)
          GestureDetector(
            onTap: () => context.push('${Routes.appStats}?pkg=${entry.key}'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                children: [
                  _PackageIcon(packageName: entry.key, catalog: catalog),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      catalog?.nameFor(entry.key) ?? entry.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: AppColors.ink),
                    ),
                  ),
                  Text(
                    _formatSeconds(entry.value),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.inkDim,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _formatSeconds(int seconds) {
    if (seconds <= 0) return '0m';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}

class _PackageIcon extends StatelessWidget {
  const _PackageIcon({required this.packageName, required this.catalog});
  final String packageName;
  final dynamic catalog;

  @override
  Widget build(BuildContext context) {
    final icon = catalog?.iconFor(packageName);
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: icon != null
          ? Image.memory(icon, width: 22, height: 22, fit: BoxFit.contain, gaplessPlayback: true)
          : Center(
              child: Text(
                packageName.isNotEmpty ? packageName.characters.first.toUpperCase() : '?',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.inkDim),
              ),
            ),
    );
  }
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(fontSize: 10, color: AppColors.inkFaint, fontWeight: FontWeight.w600));
  }
}

/// "Today" filter top panel: today's total + device-wide hourly bars.
class _TodayPanel extends ConsumerWidget {
  const _TodayPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todaySeconds = ref.watch(todayScreenTimeProvider).valueOrNull?.inSeconds ?? 0;
    final hourly = ref.watch(deviceHourlyUsageProvider).valueOrNull ?? const <int>[];
    final anyData = hourly.any((v) => v > 0);

    return PremiumCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Today',
              style: TextStyle(
                  fontSize: AppText.caption,
                  color: AppColors.inkDim,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            todaySeconds > 0 ? formatDurationHMS(Duration(seconds: todaySeconds)) : '0m',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.ink),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 120,
            child: anyData
                ? _TodayHourlyBars(hourly: hourly)
                : Center(
                    child: Text('No usage today yet',
                        style: TextStyle(fontSize: 11.5, color: AppColors.inkFaint)),
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
    );
  }
}

/// 24 hourly bars with y-axis gridlines (like the per-app stats card).
class _TodayHourlyBars extends StatelessWidget {
  const _TodayHourlyBars({required this.hourly});
  final List<int> hourly;

  @override
  Widget build(BuildContext context) {
    final max = hourly.isEmpty ? 0 : hourly.reduce((a, b) => a > b ? a : b);
    final yMax = max > 0 ? ((max / 3600).ceil() * 3600).clamp(900, 3600) : 3600;

    return Column(
      children: [
        SizedBox(
          height: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final label in ['${yMax ~/ 60}m', '${(yMax ~/ 2) ~/ 60}m', '0m'])
                Text(label, style: TextStyle(fontSize: 9, color: AppColors.inkFaint)),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(24, (h) {
              final value = h < hourly.length ? hourly[h] : 0;
              final normalized = yMax == 0 ? 0.0 : (value / yMax).clamp(0.0, 1.0);
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        height: 30 * normalized + 2,
                        decoration: BoxDecoration(
                          color: value > 0 ? AppColors.ink : AppColors.surface2,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}
