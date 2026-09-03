import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/apps_repository.dart';
import '../../data/providers.dart';
import '../../shared/widgets/duration_flow.dart';
import '../../shared/widgets/hourly_bar_chart.dart';
import '../../shared/widgets/spring_scroll.dart';

/// Screen Time detail page. A horizontal DATE STRIP (today →
/// yesterday → … up to 3 months back) drives everything: the top card
/// shows the selected day's total + device-wide hourly bars, and the
/// app list below shows that day's per-app usage. Everything updates
/// dynamically as the selected date changes.
class ScreenTimeScreen extends ConsumerStatefulWidget {
  const ScreenTimeScreen({super.key});

  @override
  ConsumerState<ScreenTimeScreen> createState() => _ScreenTimeScreenState();
}

class _ScreenTimeScreenState extends ConsumerState<ScreenTimeScreen> {
  // Selected calendar day (local midnight). Defaults to today.
  late DateTime _selectedDay = _today();

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    // Re-anchor if the page is kept alive across midnight.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_selectedDay != _today()) setState(() => _selectedDay = _today());
    });
  }

  @override
  Widget build(BuildContext context) {
    final today = _today();
    // When the selected day is TODAY, the top total ticks live (DB
    // total + pending foreground window); past days are static.
    final isToday = _selectedDay == today;
    final dayTotalSeconds = isToday
        ? (ref.watch(liveScreenTimeSecondsProvider).valueOrNull ?? 0)
        : (ref.watch(dayScreenTimeProvider(_selectedDay)).valueOrNull?.inSeconds ?? 0);
    final hourly = ref.watch(dayHourlyUsageProvider(_selectedDay)).valueOrNull ?? const <int>[];

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
          // Date strip: today → 3 months back.
          _DateStrip(
            selectedDay: _selectedDay,
            today: today,
            onSelect: (day) => setState(() => _selectedDay = day),
          ),
          const SizedBox(height: 18),

          // Selected-day total + device-wide hourly bars.
          PremiumCard(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(_dayTitle(_selectedDay, today),
                          style: TextStyle(
                              fontSize: AppText.caption,
                              color: AppColors.inkDim,
                              fontWeight: FontWeight.w600)),
                    ),
                    Text(_dayDetail(_selectedDay, today),
                        style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint)),
                  ],
                ),
                const SizedBox(height: 4),
                dayTotalSeconds > 0
                    ? DurationFlow(
                        Duration(seconds: dayTotalSeconds),
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.ink),
                      )
                    : Text('No data',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.ink)),
                const SizedBox(height: 10),
                HourlyBarChart(hourly: hourly, height: 130),
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
          const SizedBox(height: 18),

          // Per-app usage for the selected day.
          _DayAppUsageList(day: _selectedDay),
        ],
      ),
    );
  }

  String _dayTitle(DateTime day, DateTime today) {
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return 'Screen time';
  }

  String _dayDetail(DateTime day, DateTime today) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[day.month - 1]} ${day.day}, ${day.year}';
  }
}

/// Horizontal date strip: Today, Yesterday, … back 90 days. Selected
/// chip inverted; future dates never offered.
class _DateStrip extends StatelessWidget {
  const _DateStrip({
    required this.selectedDay,
    required this.today,
    required this.onSelect,
  });

  final DateTime selectedDay;
  final DateTime today;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final offsets = List.generate(90, (i) => i);
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: springScrollPhysics,
        itemCount: offsets.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final day = today.subtract(Duration(days: i));
          final selected = day == selectedDay;
          final label = _chipLabel(i, day);
          return GestureDetector(
            onTap: () => onSelect(day),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: selected ? AppColors.ink : AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: selected ? null : Border.all(color: AppColors.stroke),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? AppColors.bg : AppColors.inkDim,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _chipLabel(int offset, DateTime day) {
    if (offset == 0) return 'Today';
    if (offset == 1) return 'Yesterday';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[day.month - 1]} ${day.day}';
  }
}

/// Per-app usage for one calendar day, sorted by time.
class _DayAppUsageList extends ConsumerWidget {
  const _DayAppUsageList({required this.day});
  final DateTime day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appMap = ref.watch(dayUsageByPackageProvider(day)).valueOrNull ?? const <String, int>{};
    final catalog = ref.watch(appsCatalogProvider).valueOrNull;

    final entries = appMap.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Text(
          'No usage on this day.',
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
