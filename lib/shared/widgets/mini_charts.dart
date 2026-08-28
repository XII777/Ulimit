import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';

/// The weekly trend chart on Home: area + line + a dashed average line.
/// Implemented once as a CustomPainter for the same reason [LimitRing]
/// is — one painter to profile, not several SVG-shaped widgets.
class WeeklyAreaChart extends StatelessWidget {
  const WeeklyAreaChart({
    super.key,
    required this.values,
    required this.average,
    this.color = AppColors.accent,
    this.height = 84,
  });

  /// One point per day, left to right, oldest first. The chart's
  /// baseline is always zero, not `values.min`.
  final List<double> values;
  final double average;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: CustomPaint(
        painter: _AreaChartPainter(values: values, average: average, color: color),
      ),
    );
  }
}

class _AreaChartPainter extends CustomPainter {
  _AreaChartPainter({required this.values, required this.average, required this.color});

  final List<double> values;
  final double average;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    final maxV = values.reduce((a, b) => a > b ? a : b);
    final range = maxV <= 0 ? 1.0 : maxV;

    double xAt(int i) => size.width * i / (values.length - 1);
    double yAt(double v) => size.height - (v / range) * size.height;

    final dashPaint = Paint()
      ..color = AppColors.inkFaint
      ..strokeWidth = 1;
    _drawDashedLine(canvas, Offset(0, yAt(average)), Offset(size.width, yAt(average)), dashPaint);

    final line = Path()..moveTo(xAt(0), yAt(values[0]));
    for (var i = 1; i < values.length; i++) {
      line.lineTo(xAt(i), yAt(values[i]));
    }

    final fill = Path.from(line)
      ..lineTo(xAt(values.length - 1), size.height)
      ..lineTo(xAt(0), size.height)
      ..close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.35), color.withOpacity(0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );

    for (var i = 0; i < values.length; i++) {
      final center = Offset(xAt(i), yAt(values[i]));
      final isLast = i == values.length - 1;
      if (isLast) {
        canvas.drawCircle(center, 4, Paint()..color = AppColors.bg);
        canvas.drawCircle(
          center,
          4,
          Paint()
            ..color = color
            ..strokeWidth = 2.5
            ..style = PaintingStyle.stroke,
        );
      } else {
        canvas.drawCircle(center, 2.5, Paint()..color = color);
      }
    }
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dashWidth = 3.0;
    const dashSpace = 4.0;
    final totalLength = (end - start).distance;
    var covered = 0.0;
    while (covered < totalLength) {
      final from = Offset.lerp(start, end, covered / totalLength)!;
      final to = Offset.lerp(start, end, ((covered + dashWidth) / totalLength).clamp(0.0, 1.0))!;
      canvas.drawLine(from, to, paint);
      covered += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(_AreaChartPainter old) =>
      old.values != values || old.average != average || old.color != color;
}
