import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';

class BedtimeScreen extends ConsumerWidget {
  const BedtimeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedule = ref.watch(bedtimeScheduleProvider);
    final db = ref.read(databaseProvider);

    return SafeArea(
      child: schedule.when(
        data: (row) => _buildBody(context, db, row),
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, __) => Center(
          child: Text('Could not load bedtime settings: $e', style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppDatabase db, BedtimeScheduleData? row) {
    // No row yet (fresh install) — show the same defaults the first
    // toggle-write will actually create, so the screen doesn't flash
    // from one set of numbers to another once a toggle is touched.
    final startTime = row?.startTime ?? '22:30';
    final endTime = row?.endTime ?? '06:30';
    final dnd = row?.dndEnabled ?? true;
    final pauseApps = row?.pauseApps ?? true;
    final grayscale = row?.grayscale ?? false;
    final protectedHours = _hoursBetween(startTime, endTime);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      children: [
        Text('Bedtime', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('Scheduled · repeats every night', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),

        Center(child: _MoonArc(progress: _nightProgress(startTime, endTime))),

        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_formatTime(startTime), style: const TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            )),
            const SizedBox(width: 10),
            const Icon(Icons.arrow_forward_rounded, size: 16, color: AppColors.inkFaint),
            const SizedBox(width: 10),
            Text(_formatTime(endTime), style: const TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            )),
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
              _ToggleRow(
                label: 'Do Not Disturb',
                subtitle: 'Silence calls & notifications',
                value: dnd,
                onChanged: (v) => db.setDndEnabled(v),
              ),
              const Divider(height: 1, color: AppColors.stroke),
              _ToggleRow(
                label: 'Pause distracting apps',
                subtitle: 'Uses the same list as invincible mode',
                value: pauseApps,
                onChanged: (v) => db.setPauseApps(v),
              ),
              const Divider(height: 1, color: AppColors.stroke),
              _ToggleRow(
                label: 'Grayscale display',
                subtitle: 'Dims the pull to check',
                value: grayscale,
                onChanged: (v) => db.setGrayscale(v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// "22:30" -> "10:30 PM". Schedule times are stored as "HH:mm" 24h
  /// strings (see BedtimeSchedule) rather than DateTime, since they
  /// repeat nightly and aren't tied to a specific date.
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
    final diff = e >= s ? e - s : (24 * 60 - s) + e; // handles overnight wrap
    return (diff / 60).round();
  }

  double _nightProgress(String start, String end) {
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final s = _minutesSinceMidnight(start);
    final e = _minutesSinceMidnight(end);
    final total = e >= s ? e - s : (24 * 60 - s) + e;
    if (total <= 0) return 0;

    final elapsed = nowMinutes >= s
        ? nowMinutes - s
        : nowMinutes <= e
            ? (24 * 60 - s) + nowMinutes
            : null;
    if (elapsed == null) return 0; // outside the window right now
    return (elapsed / total).clamp(0.0, 1.0);
  }

  int _minutesSinceMidnight(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }
}

/// Open half-arc (not a full [LimitRing]) representing tonight's
/// schedule window — deliberately a separate small painter rather than
/// stretching LimitRing to support open arcs, since LimitRing's contract
/// (full 0–2π sweep) is used correctly everywhere else and shouldn't
/// grow a special case for this one screen.
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

  static const _start = 3.14159; // 180deg
  static const _sweepTotal = 3.14159; // 180deg total arc

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 10);
    final radius = size.width / 2 - 10;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawArc(
      rect,
      _start,
      _sweepTotal,
      false,
      Paint()
        ..color = AppColors.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    canvas.drawArc(
      rect,
      _start,
      _sweepTotal * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..color = AppColors.accent
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11)),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: AppColors.bg,
              activeTrackColor: AppColors.accent,
              inactiveThumbColor: AppColors.inkFaint,
              inactiveTrackColor: AppColors.surface2,
              trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
            ),
          ],
        ),
      ),
    );
  }
}
