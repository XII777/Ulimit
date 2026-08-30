import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/restriction_engine.dart';
import '../../core/icons/app_icons.dart';
import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/db/app_database.dart';
import '../../data/focus_providers.dart';
import '../../shared/widgets/app_sheet.dart';
import '../../shared/widgets/spring_scroll.dart';

/// Focus Time history: all completed sessions grouped by local calendar
/// date, with per-day totals — date, daily total, then every session's
/// start, end and duration. Real stored data only.
class FocusHistoryScreen extends ConsumerWidget {
  const FocusHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(focusHistoryProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: AppIcon(AppIconName.back, size: 15, color: AppColors.inkDim),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Focus Time',
                            style: TextStyle(
                                fontSize: AppText.headline,
                                fontWeight: FontWeight.w600,
                                color: AppColors.ink)),
                        Text('Session history',
                            style: TextStyle(fontSize: AppText.caption, color: AppColors.inkDim)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: sessions.when(
                data: (rows) {
                  if (rows.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIcon(AppIconName.stopwatch, size: 22, color: AppColors.inkFaint),
                          const SizedBox(height: 10),
                          Text('No sessions yet',
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.ink)),
                          const SizedBox(height: 4),
                          Text(
                            'Completed Focus Sessions appear here,\ngrouped by day.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11.5, color: AppColors.inkFaint, height: 1.5),
                          ),
                        ],
                      ),
                    );
                  }

                  // Group by local calendar date, newest day first;
                  // sessions within a day ordered newest first.
                  final groups = <DateTime, List<FocusSession>>{};
                  for (final s in rows) {
                    final day = DateTime(s.startedAt.year, s.startedAt.month, s.startedAt.day);
                    groups.putIfAbsent(day, () => []).add(s);
                  }
                  final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));

                  return ListView.separated(
                    physics: springScrollPhysics,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                    itemCount: days.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 20),
                    itemBuilder: (context, i) {
                      final day = days[i];
                      final daySessions = groups[day]!
                        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
                      final totalSeconds = daySessions.fold<int>(
                          0, (sum, s) => sum + FocusClock.elapsedSeconds(s, s.endedAt ?? DateTime.now()));
                      return _DayGroup(
                        day: day,
                        totalSeconds: totalSeconds,
                        sessions: daySessions,
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                error: (e, _) => Center(
                  child: Text('Could not load history: $e',
                      style: TextStyle(fontSize: 12, color: AppColors.inkFaint)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayGroup extends ConsumerWidget {
  const _DayGroup({required this.day, required this.totalSeconds, required this.sessions});

  final DateTime day;
  final int totalSeconds;
  final List<FocusSession> sessions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_dayLabel(day),
                style: TextStyle(
                    fontSize: AppText.title, fontWeight: FontWeight.w600, color: AppColors.ink)),
            Text(formatDurationHMS(Duration(seconds: totalSeconds)),
                style: TextStyle(
                    fontSize: AppText.title,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
        const SizedBox(height: 2),
        Text(_dateLabel(day),
            style: TextStyle(fontSize: AppText.caption, color: AppColors.inkFaint)),
        const SizedBox(height: 10),
        for (final s in sessions) ...[
          _SessionTile(session: s),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(d.year, d.month, d.day);
    final diff = today.difference(target).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return weekdays[d.weekday - 1];
  }

  String _dateLabel(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session});
  final FocusSession session;

  @override
  Widget build(BuildContext context) {
    final start = TimeOfDay.fromDateTime(session.startedAt).format(context);
    final end = session.endedAt != null
        ? TimeOfDay.fromDateTime(session.endedAt!).format(context)
        : '…';
    final duration = FocusClock.elapsedSeconds(session, session.endedAt ?? DateTime.now());
    final completed = session.completed;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: AppIcon(AppIconName.stopwatch, size: 16, color: AppColors.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(session.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: AppText.body, color: AppColors.ink)),
                const SizedBox(height: 2),
                Text('$start — $end',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.inkDim,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(formatDurationHMS(Duration(seconds: duration)),
                  style: TextStyle(
                      fontSize: AppText.body,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink,
                      fontFeatures: [FontFeature.tabularFigures()])),
              const SizedBox(height: 2),
              Text(
                completed ? 'Completed' : 'Ended early',
                style: TextStyle(fontSize: 10, color: AppColors.inkFaint),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
