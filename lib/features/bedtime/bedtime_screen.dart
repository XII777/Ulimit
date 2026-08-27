import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';

class BedtimeScreen extends StatefulWidget {
  const BedtimeScreen({super.key});

  @override
  State<BedtimeScreen> createState() => _BedtimeScreenState();
}

class _BedtimeScreenState extends State<BedtimeScreen> {
  // Local toggle state for now — swap for BedtimeSchedule row writes
  // (the table already exists: dndEnabled/pauseApps/grayscale) once a
  // bedtimeScheduleProvider lands; this widget's shape won't change,
  // only where these three bools come from.
  bool _dnd = true;
  bool _pauseApps = true;
  bool _grayscale = false;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
        children: [
          Text('Bedtime', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Scheduled · repeats every night', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),

          const Center(child: _MoonArc(progress: 0.72)),

          const SizedBox(height: 4),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('10:30 PM', style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              )),
              SizedBox(width: 10),
              Icon(Icons.arrow_forward_rounded, size: 16, color: AppColors.inkFaint),
              SizedBox(width: 10),
              Text('6:30 AM', style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              )),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '8 hours protected',
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
                  value: _dnd,
                  onChanged: (v) => setState(() => _dnd = v),
                ),
                const Divider(height: 1, color: AppColors.stroke),
                _ToggleRow(
                  label: 'Pause distracting apps',
                  subtitle: '12 apps included',
                  value: _pauseApps,
                  onChanged: (v) => setState(() => _pauseApps = v),
                ),
                const Divider(height: 1, color: AppColors.stroke),
                _ToggleRow(
                  label: 'Grayscale display',
                  subtitle: 'Dims the pull to check',
                  value: _grayscale,
                  onChanged: (v) => setState(() => _grayscale = v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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

  // Half-circle opening downward, matching the design: sweeps from
  // 180° (9 o'clock) to 360° (3 o'clock) across the top.
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
