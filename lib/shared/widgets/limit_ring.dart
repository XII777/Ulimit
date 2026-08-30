import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';

/// The app's recurring ring motif (screen-time budget, focus countdown,
/// group allowance, sleep arc). Implemented once as a CustomPainter and
/// reused everywhere with different `progress`/color inputs, rather than
/// four separate SVG-in-a-Container implementations per screen — one
/// painter to profile, one to optimize.
class LimitRing extends StatelessWidget {
  LimitRing({
    super.key,
    required this.progress,
    required this.size,
    this.strokeWidth = 10,
    Color? color,
    Color? trackColor,
    this.child,
  })  : color = color ?? AppColors.accent,
        trackColor = trackColor ?? AppColors.stroke;

  /// 0.0–1.0. Callers animate this externally (e.g. with
  /// TweenAnimationBuilder) rather than the ring owning a controller —
  /// keeps this widget stateless and trivially reusable.
  final double progress;
  final double size;
  final double strokeWidth;
  final Color color;
  final Color trackColor;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _RingPainter(
              progress: progress,
              strokeWidth: strokeWidth,
              color: color,
              trackColor: trackColor,
            ),
          ),
          if (child != null) child!,
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.strokeWidth,
    required this.color,
    required this.trackColor,
  });

  final double progress;
  final double strokeWidth;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.width - strokeWidth) / 2;

    final track = Paint()
      ..color = trackColor
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final fill = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawCircle(center, radius, track);

    const start = -1.5708; // -90deg, 12 o'clock
    final sweep = 6.28319 * progress.clamp(0.0, 1.0); // 2π
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      fill,
    );
  }

  // Only repaint when the values that actually affect pixels change —
  // this is what makes it safe to rebuild this widget every animation
  // tick without dropping frames.
  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}
