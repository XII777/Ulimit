import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';

/// A single-series area/line chart, drawn with one CustomPainter instead
/// of pulling in fl_chart/syncfusion — those pull in far more than this
/// app needs (legends, tooltips, multi-axis support) for what's really
/// 7-14 points on a card. Keeps the app's dependency footprint small,
/// per the "don't make it too large" requirement.
class TrendAreaChart extends StatelessWidget {
  TrendAreaChart({
    super.key,
    required this.values,
    this.height = 84,
    Color? color,
    this.showAverageLine = true,
  }) : color = color ?? AppColors.accent;

  /// Normalized or raw values — only relative shape matters, the
  /// painter rescales internally to fit [height].
  final List<double> values;
  final double height;
  final Color color;
  final bool showAverageLine;

  Color get effectiveColor => color ?? AppColors.accent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      // TweenAnimationBuilder animates the whole series in on first
      // build (0 → 1) rather than snapping the chart in fully drawn —
      // a small motion detail that reads as "designed", not free.
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => CustomPaint(
          painter: _AreaChartPainter(
            values: values,
            progress: t,
            color: effectiveColor,
            showAverageLine: showAverageLine,
          ),
        ),
      ),
    );
  }
}

class _AreaChartPainter extends CustomPainter {
  _AreaChartPainter({
    required this.values,
    required this.progress,
    required this.color,
    required this.showAverageLine,
  });

  final List<double> values;
  final double progress;
  final Color color;
  final bool showAverageLine;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);
    final range = (maxV - minV).abs() < 0.001 ? 1.0 : (maxV - minV);

    // Reserve bottom 14px so the line never touches the day-label row
    // that typically sits directly under this widget.
    final usableHeight = size.height - 6;
    final stepX = size.width / (values.length - 1);

    Offset pointAt(int i) {
      final normalized = (values[i] - minV) / range;
      final y = usableHeight - (normalized * usableHeight) + 4;
      return Offset(stepX * i, y);
    }

    final visibleCount = (values.length * progress).ceil().clamp(2, values.length);
    final points = [for (var i = 0; i < visibleCount; i++) pointAt(i)];

    if (showAverageLine) {
      final avgNormalized = (values.reduce((a, b) => a + b) / values.length - minV) / range;
      final y = usableHeight - (avgNormalized * usableHeight) + 4;
      final dashPaint = Paint()
        ..color = AppColors.inkFaint
        ..strokeWidth = 1;
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(Offset(x, y), Offset(x + 3, y), dashPaint);
        x += 7;
      }
    }

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, linePaint);

    // Faded translucent gradient under the line: fills the area below
    // the series with a linear gradient (color@0.18 → transparent) so
    // the chart's backdrop reads as a soft fade rather than a flat
    // tint. Driven by [progress] so the fade-in animates with the line.
    final fillPath = Path.from(path)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    final fillColor = color.withValues(alpha: 0.18 * progress);
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          fillColor.withValues(alpha: fillColor.a),
          fillColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(fillPath, fillPaint);

    // Endpoint dot — hollow ring, matches the mockup's highlighted
    // final point.
    if (points.length == values.length) {
      final last = points.last;
      canvas.drawCircle(last, 4, Paint()..color = AppColors.bg);
      canvas.drawCircle(
        last,
        4,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  @override
  bool shouldRepaint(_AreaChartPainter old) =>
      old.progress != progress || old.values != values || old.color != color;
}

/// Compact single-line sparkline for the small stat cards (Focus time,
/// Pickups) — no fill, no average line, minimal footprint.
class Sparkline extends StatelessWidget {
  Sparkline({
    super.key,
    required this.values,
    this.height = 36,
    Color? color,
  }) : color = color ?? AppColors.accent;

  final List<double> values;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => CustomPaint(
          painter: _SparklinePainter(values: values, progress: t, color: color),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.progress, required this.color});
  final List<double> values;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);
    final range = (maxV - minV).abs() < 0.001 ? 1.0 : (maxV - minV);
    final stepX = size.width / (values.length - 1);

    Offset pointAt(int i) {
      final normalized = (values[i] - minV) / range;
      return Offset(stepX * i, size.height - normalized * size.height);
    }

    final visibleCount = (values.length * progress).ceil().clamp(2, values.length);
    final path = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);
    for (var i = 1; i < visibleCount; i++) {
      final p = pointAt(i);
      path.lineTo(p.dx, p.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.progress != progress || old.values != values;
}
