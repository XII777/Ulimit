import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/restriction_engine.dart';
import '../../core/icons/app_icons.dart';
import '../../core/native/enforcement_channel.dart';
import '../../core/theme/tokens.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../shared/widgets/app_selector.dart';
import '../../shared/widgets/pressable_scale.dart';
import '../../shared/widgets/spring_scroll.dart';

class BedtimeScreen extends ConsumerWidget {
  const BedtimeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedule = ref.watch(bedtimeScheduleProvider);
    final db = ref.watch(databaseProvider);

    return schedule.when(
      data: (row) => _Body(row: row, db: db, ref: ref),
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, __) => Center(
        child: Text('Could not load bedtime settings: $e',
            style: Theme.of(context).textTheme.bodySmall),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.row, required this.db, required this.ref});

  final BedtimeScheduleData? row;
  final AppDatabase db;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = row?.enabled ?? false;
    final startTime = row?.startTime ?? '22:30';
    final endTime = row?.endTime ?? '06:30';
    final dnd = row?.dndEnabled ?? true;
    final pauseApps = row?.pauseApps ?? true;
    final internet = row?.blockInternet ?? false;
    final grayscale = row?.grayscale ?? false;
    final apps = row?.selectedApps ?? const <String>[];
    final protectedHours = _hoursBetween(startTime, endTime);

    return ListView(
      physics: springScrollPhysics,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 110),
      children: [
        Text('Bedtime', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(enabled ? 'Scheduled · repeats every night' : 'Schedule is off',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),

        Center(child: _MoonArc(progress: enabled ? _nightProgress(startTime, endTime) : 0.0)),

        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: () => _pickTime(context, isStart: true),
              child: Text(_formatTime(startTime),
                  style: GoogleFonts.spaceGrotesk(
                      fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.ink)),
            ),
            const SizedBox(width: 10),
            AppIcon(AppIconName.chevronRight, size: 16, color: AppColors.inkFaint),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () => _pickTime(context, isStart: false),
              child: Text(_formatTime(endTime),
                  style: GoogleFonts.spaceGrotesk(
                      fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.ink)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '$protectedHours hours protected',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5),
        ),
        const SizedBox(height: 20),

        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.stroke),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Column(
            children: [
              SwitchListTile(
                title: Text('Bedtime enabled', style: TextStyle(fontSize: 13.5, color: AppColors.ink)),
                subtitle: Text('Restrictions activate every night',
                    style: TextStyle(fontSize: 11, color: AppColors.inkFaint)),
                value: enabled,
                onChanged: (v) => _setEnabled(context, v),
                activeTrackColor: AppColors.ink,
                activeColor: AppColors.bg,
              ),
              Divider(height: 1, color: AppColors.stroke),
              _ToggleRow(
                label: 'Do Not Disturb',
                subtitle: 'Silence calls & notifications',
                value: dnd,
                onChanged: (v) async {
                  await db.setDndEnabled(v);
                  await _rescheduleAlarms();
                },
              ),
              Divider(height: 1, color: AppColors.stroke),
              _ToggleRow(
                label: 'Pause distracting apps',
                subtitle: 'Selected apps are blocked all night',
                value: pauseApps,
                onChanged: (v) async {
                  await db.setPauseApps(v);
                  await _rescheduleAlarms();
                },
              ),
              Divider(height: 1, color: AppColors.stroke),
              _ToggleRow(
                label: 'Block internet',
                subtitle: 'All apps lose network access during bedtime',
                value: internet,
                onChanged: (v) async {
                  await db.setBedtimeInternet(v);
                  await _rescheduleAlarms();
                },
              ),
              Divider(height: 1, color: AppColors.stroke),
              _ToggleRow(
                label: 'Grayscale display',
                subtitle: 'Dims the pull to check',
                value: grayscale,
                onChanged: (v) => db.setGrayscale(v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        PressableScale(
          onTap: pauseApps ? () => _pickApps(context) : null,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: AppColors.stroke),
            ),
            child: apps.isEmpty
                ? Text('Choose apps to pause overnight',
                    style: TextStyle(fontSize: 13, color: AppColors.inkDim))
                : Text('${apps.length} apps pause overnight',
                    style: TextStyle(fontSize: 13, color: AppColors.ink)),
          ),
        ),
      ],
    );
  }

  Future<void> _setEnabled(BuildContext context, bool value) async {
    await db.setBedtimeEnabled(value);
    await _rescheduleAlarms();
    if (value) {
      final bedtime = await (db.select(db.bedtimeSchedule)..limit(1)).getSingleOrNull();
      if (bedtime != null && bedtime.dndEnabled) {
        // If the schedule is being turned on by hand, apply DND right
        // away when currently inside the window; the daily alarm keeps
        // it correct on every other day.
        await EnforcementChannel.setDnd(true);
      }
    }
  }

  Future<void> _rescheduleAlarms() async {
    final bedtime = await (db.select(db.bedtimeSchedule)..limit(1)).getSingleOrNull();
    final enabled = bedtime?.enabled ?? false;
    await EnforcementChannel.setBedtimeAlarms(
      enabled: enabled,
      startTime: bedtime?.startTime ?? '22:30',
      endTime: bedtime?.endTime ?? '06:30',
    );
  }

  Future<void> _pickTime(BuildContext context, {required bool isStart}) async {
    final current = (isStart ? row?.startTime : row?.endTime) ?? '22:30';
    final parts = current.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          timePickerTheme: TimePickerThemeData(
            backgroundColor: AppColors.surface,
            hourMinuteTextColor: AppColors.ink,
            dialHandColor: AppColors.ink,
            dialBackgroundColor: AppColors.surface2,
            dayPeriodColor: AppColors.surface2,
            dayPeriodTextColor: AppColors.ink,
          ),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;
    final hhmm = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    if (isStart) {
      await db.setBedtimeTimes(hhmm, row?.endTime ?? '06:30');
    } else {
      await db.setBedtimeTimes(row?.startTime ?? '22:30', hhmm);
    }
    await _rescheduleAlarms();
  }

  Future<void> _pickApps(BuildContext context) async {
    final result = await showAppSelector(
      context,
      title: 'Pause overnight',
      multiSelect: true,
      initiallySelected: (row?.selectedApps ?? const <String>[]).toSet(),
    );
    if (result is Set<String>) {
      await db.setBedtimeApps(result.toList());
    }
  }

  String _formatTime(String hhmm) {
    final parts = hhmm.split(':');
    var h = int.parse(parts[0]);
    final m = parts[1];
    final suffix = h >= 12 ? 'PM' : 'AM';
    h = h % 12;
    if (h == 0) h = 12;
    return '$h:$m $suffix';
  }

  int _hoursBetween(String start, String end) {
    final s = _minutesSinceMidnight(start);
    final e = _minutesSinceMidnight(end);
    final diff = e >= s ? e - s : (24 * 60 - s) + e;
    return (diff / 60).round();
  }

  double _nightProgress(String start, String end) {
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final s = _minutesSinceMidnight(start);
    final e = _minutesSinceMidnight(end);
    final total = e >= s ? e - s : (24 * 60 - s) + e;
    if (total <= 0) return 0;

    final inWindow = isMinuteInWindow(nowMinutes, s, e);
    if (!inWindow) return 0;
    final elapsed = nowMinutes >= s ? nowMinutes - s : (24 * 60 - s) + nowMinutes;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  int _minutesSinceMidnight(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }
}

class _MoonArc extends StatelessWidget {
  const _MoonArc({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      height: 140,
      child: CustomPaint(painter: _MoonArcPainter(progress: progress)),
    );
  }
}

class _MoonArcPainter extends CustomPainter {
  _MoonArcPainter({required this.progress});
  final double progress;

  static const _start = 3.14159;
  static const _sweepTotal = 3.14159;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 10);
    final radius = size.width / 2 - 10;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawArc(rect, _start, _sweepTotal, false,
        Paint()..color = AppColors.stroke..strokeWidth = 10..strokeCap = StrokeCap.round..style = PaintingStyle.stroke);
    canvas.drawArc(rect, _start, _sweepTotal * progress.clamp(0.0, 1.0), false,
        Paint()..color = AppColors.ink..strokeWidth = 10..strokeCap = StrokeCap.round..style = PaintingStyle.stroke);

    final dotPaint = Paint()..color = AppColors.ink;
    canvas.drawCircle(Offset(center.dx - radius, center.dy), 5, dotPaint);
    canvas.drawCircle(Offset(center.dx + radius, center.dy), 5, dotPaint);
  }

  @override
  bool shouldRepaint(_MoonArcPainter old) => old.progress != progress;
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 13.5, color: AppColors.ink)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 11, color: AppColors.inkFaint)),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: AppColors.ink,
              activeColor: AppColors.bg,
            ),
          ],
        ),
      ),
    );
  }
}
