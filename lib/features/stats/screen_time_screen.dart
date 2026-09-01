import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/icons/app_icons.dart';
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

          // Weekly trend graph
          PremiumCard(
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
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.ink),
                ),
                const SizedBox(height: 8),
                TrendAreaChart(values: weeklyHours, color: AppColors.ink, showAverageLine: true),
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
