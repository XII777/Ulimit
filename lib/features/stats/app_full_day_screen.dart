import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/apps_repository.dart';
import '../../data/providers.dart';
import '../../shared/widgets/spring_scroll.dart';

/// Per-app full history: every calendar day from today back 90 days as
/// a bar graph with the daily time. All data comes from the DB-backed
/// `app_usage` table (this app tracks every day locally; UsageStats
/// sync back-fills 90 days with OS-verified numbers).
class AppFullDayScreen extends ConsumerWidget {
  const AppFullDayScreen({super.key, required this.packageName});

  final String packageName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(appDayHistoryProvider(packageName)).valueOrNull;
    final catalog = ref.watch(appsCatalogProvider).valueOrNull;
    final name = catalog?.nameFor(packageName) ?? packageName;

    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day).subtract(const Duration(days: 89));
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];

    // Dynamic month labels at intervals: 0 (today), 30, 60, 90.
    final monthLabels = <Widget>[];
    for (final offset in [0, 30, 60, 90]) {
      if (offset > 89) break;
      final d = today.subtract(Duration(days: offset));
      monthLabels.add(_MonthLabel('${months[d.month - 1]}'));
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.ink,
        title: Text('$name · Full day history',
            style: Theme.of(context).textTheme.titleMedium),
      ),
      body: ListView(
        physics: springScrollPhysics,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
        children: [
          _historyCard(context, history, today),
          const SizedBox(height: 18),
          // Optional: day labels row (mo/day of oldest -> today trend).
          Text('90-day history',
              style: TextStyle(
                  fontSize: AppText.caption, color: AppColors.inkFaint, letterSpacing: 0.6)),
        ],
      ),
    );
  }

  Widget _historyCard(BuildContext context, (List<int>, int)? history, DateTime today) {
    final (values, total) = history ?? (List.filled(90, 0), 0);
    final max = values.isEmpty ? 0 : values.reduce((a, b) => a > b ? a : b);
    final anyData = values.any((v) => v > 0);

    return PremiumCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('All time',
              style: TextStyle(
                  fontSize: AppText.caption, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            total > 0 ? _fmt(total) : 'No data',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 130,
            child: anyData
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: List.generate(90, (i) {
                            final v = values[i];
                            final normalized =
                                max == 0 ? 0.0 : (v / max).clamp(0.0, 1.0);
                            return Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 0.5),
                                child: _DailyBarTooltip(
                                  value: v,
                                  day: _dayLabel(today, i),
                                  height: 130 * normalized + 2,
                                  highlighted: i == 89,
                                ),
                              ),
                            );
                          }),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 34,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (final tick in _axisTicks(max))
                              Text('${tick}m',
                                  style: TextStyle(fontSize: 9, color: AppColors.inkFaint)),
                          ],
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: Text('No history yet — start tracking to build it.',
                        style: TextStyle(fontSize: 11.5, color: AppColors.inkFaint)),
                  ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('3 months ago',
                  style: TextStyle(fontSize: 9, color: AppColors.inkFaint)),
              Text('Today', style: TextStyle(fontSize: 9, color: AppColors.inkFaint)),
            ],
          ),
        ],
      ),
    );
  }

  List<String> _axisTicks(int maxSeconds) {
    if (maxSeconds <= 0) return const ['60', '30', '0'];
    final yMax = ((maxSeconds / 3600).ceil() * 60).clamp(15, 60).toInt();
    return ['$yMax', '${yMax ~/ 2}', '0'];
  }

  String _fmt(int seconds) {
    if (seconds <= 0) return '0m';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  String _dayLabel(DateTime today, int offset) {
    final d = today.subtract(Duration(days: 89 - offset));
    return '${d.month}/${d.day}';
  }
}

/// A single history bar with a tap-to-poke time bubble.
class _DailyBarTooltip extends StatefulWidget {
  const _DailyBarTooltip({
    required this.value,
    required this.day,
    required this.height,
    this.highlighted = false,
  });

  final int value;
  final String day;
  final double height;
  final bool highlighted;

  @override
  State<_DailyBarTooltip> createState() => _DailyBarTooltipState();
}

class _DailyBarTooltipState extends State<_DailyBarTooltip> {
  bool _poked = false;

  @override
  Widget build(BuildContext context) {
    String fmt(int seconds) {
      if (seconds <= 0) return '0m';
      final h = seconds ~/ 3600;
      final m = (seconds % 3600) ~/ 60;
      if (h > 0) return '${h}h ${m}m';
      return '${m}m';
    }

    return GestureDetector(
      onTap: () {
        if (widget.value <= 0) return;
        setState(() => _poked = !_poked);
      },
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (_poked)
            Container(
              margin: const EdgeInsets.only(bottom: 3),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.ink,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text('${fmt(widget.value)}',
                  maxLines: 1,
                  style: TextStyle(fontSize: 8.5, color: AppColors.bg)),
            ),
          Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: widget.value > 0
                  ? (widget.highlighted ? AppColors.ink : AppColors.surface2)
                  : AppColors.stroke.withValues(alpha: 0.4),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthLabel extends StatelessWidget {
  const _MonthLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(fontSize: 9, color: AppColors.inkFaint, fontWeight: FontWeight.w600));
  }
}
