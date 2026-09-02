import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/icons/app_icons.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/apps_repository.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../features/limits/limits_screen.dart' show showAppLimitEditor;
import '../../shared/widgets/app_sheet.dart';
import '../../shared/widgets/hourly_bar_chart.dart';
import '../../shared/widgets/spring_scroll.dart';

/// Per-app statistics page (opened by tapping an app in the Screen Time
/// list). Mirrors Digital Wellbeing's app detail: colored app card with
/// today's usage + limit, the hourly Usage Today chart, Weekly Usage
/// with the prior-week delta, the App Limits progress, and App Controls
/// quick actions (block now / focus mode). The Usage chart follows the
/// selected day (date strip via the View Full Day long-press popup).
class AppStatsScreen extends ConsumerStatefulWidget {
  const AppStatsScreen({super.key, required this.packageName});

  final String packageName;

  /// Local-midnight of the current day.
  static DateTime today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  ConsumerState<AppStatsScreen> createState() => _AppStatsScreenState();
}

class _AppStatsScreenState extends ConsumerState<AppStatsScreen> {
  // Selected calendar day (local midnight). Defaults to today.
  late DateTime _selectedDay = AppStatsScreen.today();

  @override
  Widget build(BuildContext context) {
    final packageName = widget.packageName;
    final ref = this.ref;
    final catalog = ref.watch(appsCatalogProvider).valueOrNull;
    final name = catalog?.nameFor(packageName) ?? packageName;
    final todaySeconds = ref.watch(appTodayUsageProvider(packageName)).valueOrNull ?? 0;
    final limit = ref.watch(appLimitsProvider).valueOrNull
        ?.firstWhere((l) => l.packageName == packageName, orElse: () => AppLimitView(
              packageName: packageName,
              limitSeconds: 0,
              usedSeconds: 0,
              enabled: false,
            ));
    final limitSeconds = (limit?.enabled ?? false) ? (limit?.limitSeconds ?? 0) : 0;
    final limitActive = limitSeconds > 0;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.ink,
        title: Text(name, style: Theme.of(context).textTheme.titleMedium),
      ),
      body: ListView(
        physics: springScrollPhysics,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
        children: [
          _AppHeaderCard(
            name: name,
            iconBytes: catalog?.iconFor(packageName),
            provider: packageName,
            usageActiveSeconds: todaySeconds,
          ),
          const SizedBox(height: 18),
          _HourlyUsageCard(
            packageName: packageName,
            selectedDay: _selectedDay,
            onViewFullDay: openDatePicker,
          ),
          const SizedBox(height: 18),
          _WeeklyUsageCard(packageName: packageName),
          const SizedBox(height: 18),
          if (limitActive) _AppLimitsCard(packageName: packageName),
          const SizedBox(height: 18),
          _AppControlsCard(packageName: packageName, appName: name),
        ],
      ),
    );
  }

  /// Hold on the View Full Day chip → the date wheel bottom sheet
  /// opens: a vertically-swiping wheel of dates (Today → 90 days back).
  /// Committing happens via a row tap or the Done button.
  Future<void> openDatePicker({Offset? anchor}) async {
    final selected = await _showDateWheelPopup(context, _selectedDay, anchor);
    if (selected != null && mounted) {
      setState(() => _selectedDay = selected);
    }
  }
}

/// Date WHEEL popup presented as a compact bottom sheet: swipe the
/// wheel up/down to scroll dates (Today → 90 days back). The row under
/// the center indicator is the current selection; committing happens
/// on a tap of a row or the Done button. Closing the sheet any other
/// way (barrier tap, drag-down, back) falls back to the date that was
/// last centered in the wheel.
Future<DateTime?> _showDateWheelPopup(
    BuildContext context, DateTime current, Offset? anchor) async {
  final today = DateTime.now();
  final todayMidnight = DateTime(today.year, today.month, today.day);
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  const rowHeight = 40.0;
  const visibleRows = 5;

  // Initial scroll offset centered on the current date.
  final currentIndex = (todayMidnight.difference(current).inDays).clamp(0, 89);
  final initialOffset = (currentIndex - (visibleRows ~/ 2)) * rowHeight;

  DateTime dayAt(int index) =>
      todayMidnight.subtract(Duration(days: index.clamp(0, 89)));

  String labelFor(int index) {
    if (index == 0) return 'Today';
    if (index == 1) return 'Yesterday';
    final d = dayAt(index);
    return '${months[d.month - 1]} ${d.day}';
  }

  // Selection tracked in the outer scope so the fallback below can
  // commit the centered row no matter how the sheet closes.
  var selectedIndex = currentIndex;

  final result = await showAppSheet<DateTime>(
    context: context,
    title: 'View full day',
    subtitle: 'Scroll the wheel to pick a date',
    initialSize: 0.5,
    minSize: 0.35,
    builder: (sheetContext, scrollController) {
      final wheelController = ScrollController(initialScrollOffset: initialOffset);

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: rowHeight * visibleRows + 2,
            width: 160,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: AppColors.stroke),
            ),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                // Center selection window.
                Positioned(
                  left: 0,
                  right: 0,
                  top: rowHeight * (visibleRows ~/ 2),
                  height: rowHeight,
                  child: IgnorePointer(
                    child: Container(
                      color: AppColors.ink.withValues(alpha: 0.10),
                      decoration: BoxDecoration(
                        border: Border.symmetric(
                            horizontal: BorderSide(color: AppColors.stroke)),
                      ),
                    ),
                  ),
                ),
                // Snapping wheel.
                ListWheelScrollView.useDelegate(
                  controller: wheelController,
                  itemExtent: rowHeight,
                  perspective: 0.002,
                  diameterRatio: 1.4,
                  physics: const FixedExtentScrollPhysics(),
                  onSelectedItemChanged: (index) => selectedIndex = index,
                  childDelegate: ListWheelChildBuilderDelegate(
                    childCount: 90,
                    builder: (context, index) => Center(
                      child: Text(
                        labelFor(index),
                        style: index == selectedIndex
                            ? TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.ink)
                            : TextStyle(fontSize: 13, color: AppColors.inkDim),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: TextButton(
              onPressed: () => Navigator.of(sheetContext).pop(dayAt(selectedIndex)),
              style: TextButton.styleFrom(
                backgroundColor: AppColors.ink,
                foregroundColor: AppColors.bg,
                padding: const EdgeInsets.all(14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md)),
              ),
              child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      );
    },
  );

  // Complete the wheel: closing the sheet (tap, drag-down, back)
  // without an explicit commit returns null — fall back to the date
  // that was last centered in the wheel.
  return result ?? dayAt(selectedIndex);
}

/// Colored header: app icon (white rounded tile), status chip
/// (Allowed when no active block), Today + Daily limit figures.
class _AppHeaderCard extends ConsumerWidget {
  const _AppHeaderCard({
    required this.name,
    required this.provider,
    required this.usageActiveSeconds,
    this.iconBytes,
  });

  final String name;
  final String provider;
  final int usageActiveSeconds;
  final dynamic iconBytes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decisions = ref.watch(restrictionDecisionsProvider);
    final decision = decisions[provider];
    final blocked = decision?.appBlocked == true;
    final limit = ref.watch(appLimitsProvider).valueOrNull
        ?.firstWhere((l) => l.packageName == provider, orElse: () => AppLimitView(
              packageName: provider,
              limitSeconds: 0,
              usedSeconds: 0,
              enabled: false,
            ));
    final limitSeconds = (limit?.enabled ?? false) ? (limit?.limitSeconds ?? 0) : 0;
    final limitActive = limitSeconds > 0;
    final remaining = limitActive ? (limitSeconds - usageActiveSeconds).clamp(0, limitSeconds) : 0;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        // Icon-derived dominant red/mono (monochrome design language:
        // the app card uses the surface tone; the header stays ink on
        // tint to keep it premium without per-app color extraction).
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.surface, AppColors.surface2],
        ),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // White rounded tile + icon (like the app-list tile).
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: iconBytes != null
                    ? Image.memory(iconBytes!,
                        width: 44, height: 44, fit: BoxFit.contain, gaplessPlayback: true)
                    : Icon(Icons.apps_rounded, color: AppColors.inkFaint, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.ink)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: blocked ? AppColors.danger : AppColors.surface2,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(blocked ? Icons.block_rounded : Icons.check_circle_outline_rounded,
                              size: 13, color: blocked ? Colors.white : AppColors.inkDim),
                          const SizedBox(width: 5),
                          Text(blocked ? 'Blocked' : 'Allowed',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: blocked ? Colors.white : AppColors.inkDim)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _HeaderMetric(
                  label: 'Today',
                  value: _fmtSecs(usageActiveSeconds),
                  hint: 'Usage',
                ),
              ),
              Container(width: 1, height: 34, color: AppColors.stroke),
              Expanded(
                child: _HeaderMetric(
                  label: 'Daily limit',
                  value: limitSeconds > 0 ? _fmtSecs(limitSeconds) : 'No limit',
                  hint: limitActive && limitSeconds > 0 ? 'Remaining ${_fmtSecs(remaining)}' : '',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderMetric extends StatelessWidget {
  const _HeaderMetric({required this.label, required this.value, this.hint = ''});
  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label,
            style: TextStyle(fontSize: 12, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
        Text(value,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.ink)),
        const SizedBox(height: 2),
        Text(hint, style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint)),
      ],
    );
  }
}

/// Hourly bar chart: per-day UsageEvents 24 buckets, y-axis caps ~60m.
class _HourlyUsageCard extends ConsumerWidget {
  const _HourlyUsageCard({
    required this.packageName,
    required this.selectedDay,
    required this.onViewFullDay,
  });

  final String packageName;
  final DateTime selectedDay;
  final Future<void> Function() onViewFullDay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isToday = selectedDay == AppStatsScreen.today();
    final hourly = isToday
        ? ref.watch(hourlyUsageProvider(packageName)).valueOrNull ?? const <int>[]
        : ref.watch(appDayHourlyUsageProvider((packageName, selectedDay))).valueOrNull ??
            const <int>[];

    return _SectionCard(
      title: isToday ? 'Usage Today' : 'Usage · ${_shortDate(selectedDay)}',
      trailing: GestureDetector(
        // Long-press opens the date picker.
        onLongPressStart: (details) => onViewFullDay(),
        onLongPressEnd: (_) {},
        onLongPressCancel: () {},
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text('View Full Day',
              style: TextStyle(
                  fontSize: 10.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
        ),
      ),
      child: HourlyBarChart(hourly: hourly, height: 140, axisTicks: const ['60m', '30m', '0m']),
    );
  }

  String _shortDate(DateTime day) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[day.month - 1]} ${day.day}';
  }
}

/// Weekly Usage: total this week + per-day bars + % vs last week.
class _WeeklyUsageCard extends ConsumerWidget {
  const _WeeklyUsageCard({required this.packageName});
  final String packageName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(appWeeklyUsageProvider(packageName)).valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0];
    final prevWeek = ref.watch(appPreviousWeekUsageProvider(packageName)).valueOrNull ?? 0;
    final total = days.fold(0, (a, b) => a + b);

    double? deltaPercent;
    if (prevWeek > 0 && total > 0) {
      deltaPercent = ((total - prevWeek) / prevWeek) * 100;
    }

    final maxDay = days.fold(0, (m, v) => v > m ? v : m);

    return _SectionCard(
      title: 'Weekly Usage',
      trailing: _WeekDeltaChip(percent: deltaPercent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${(total / 3600).floor()}h ${((total % 3600) / 60).floor()}m',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink),
          ),
          Text('Total this week',
              style: TextStyle(fontSize: 11, color: AppColors.inkDim)),
          const SizedBox(height: 14),
          SizedBox(
            height: 74,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(7, (i) {
                final v = i < days.length ? days[i] : 0;
                final h = maxDay == 0 ? 4.0 : (4 + 34 * (v / maxDay));
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(height: h, decoration: BoxDecoration(
                          color: i == 6 ? AppColors.ink : AppColors.surface2,
                          borderRadius: BorderRadius.circular(4),
                        )),
                        const SizedBox(height: 6),
                        Text(_weekLetters()[i],
                            style: TextStyle(fontSize: 9, color: AppColors.inkFaint)),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  /// Weekday letters for the current 7-day window (oldest→today),
  /// derived from the real dates so the rightmost label is today.
  static List<String> _weekLetters() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return [
      for (var i = 0; i < 7; i++) letters[start.add(Duration(days: i)).weekday - 1],
    ];
  }
}

class _WeekDeltaChip extends StatelessWidget {
  const _WeekDeltaChip({this.percent});
  final double? percent;

  @override
  Widget build(BuildContext context) {
    final p = percent;
    if (p == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(p >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
              size: 12, color: AppColors.inkDim),
          const SizedBox(width: 4),
          Text('${p.abs().toStringAsFixed(0)}% vs last week',
              style: TextStyle(fontSize: 10, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// App Limits: daily limit, progress bar, edit button.
class _AppLimitsCard extends ConsumerWidget {
  const _AppLimitsCard({required this.packageName});
  final String packageName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final limit = ref.watch(appLimitsProvider).valueOrNull
        ?.firstWhere((l) => l.packageName == packageName, orElse: () => AppLimitView(
              packageName: packageName,
              limitSeconds: 0,
              usedSeconds: 0,
              enabled: false,
            ));
    final used = limit?.usedSeconds ?? 0;
    final total = limit?.limitSeconds ?? 0;
    final ratio = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;

    return _SectionCard(
      icon: AppIconName.limits,
      title: 'App Limits',
      trailing: GestureDetector(
        onTap: () => showAppLimitEditor(context, ref, packageName: packageName),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text('Edit Limit',
              style: TextStyle(fontSize: 10.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Daily Limit',
              style: TextStyle(fontSize: 11, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(total > 0 ? _fmtSecs(total) : 'No limit set',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.ink)),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 5,
              backgroundColor: AppColors.surface2,
              valueColor: AlwaysStoppedAnimation(AppColors.ink),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${_fmtSecs(used)} used',
                  style: TextStyle(fontSize: 10.5, color: AppColors.inkDim)),
              Text('${_fmtSecs((total - used).clamp(0, total))} remaining',
                  style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint)),
            ],
          ),
        ],
      ),
    );
  }
}

/// App Controls quick actions: App Blocker, Focus Mode.
class _AppControlsCard extends StatelessWidget {
  const _AppControlsCard({required this.packageName, required this.appName});
  final String packageName;
  final String appName;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      icon: AppIconName.shield,
      title: 'App Controls',
      child: Row(
        children: [
          Expanded(
            child: _ControlButton(
              icon: AppIconName.block,
              label: 'App Blocker',
              hint: 'Block $appName',
              onTap: () => context.push('${Routes.restrictions}?pkg=$packageName'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ControlButton(
              icon: AppIconName.stopwatch,
              label: 'Focus Mode',
              hint: 'Pause distractions',
              onTap: () => context.push(Routes.focus),
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.hint,
    required this.onTap,
  });
  final AppIconName icon;
  final String label;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(8),
              ),
              child: AppIcon(icon, size: 15, color: AppColors.ink),
            ),
            const SizedBox(height: 10),
            Text(label,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.ink)),
            Text(hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: AppColors.inkFaint)),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.trailing,
    this.icon,
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final AppIconName? icon;

  @override
  Widget build(BuildContext context) {
    return PremiumCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                AppIcon(icon!, size: 14, color: AppColors.inkDim),
                const SizedBox(width: 7),
              ],
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: AppColors.inkDim,
                        fontWeight: FontWeight.w600)),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

String _fmtSecs(int seconds) {
  if (seconds <= 0) return '0m';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
