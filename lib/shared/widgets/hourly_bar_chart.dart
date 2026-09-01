import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/engine/restriction_engine.dart' show formatDurationShort;
import '../../core/theme/tokens.dart';

/// 24-bar hourly usage chart with:
///  - a vertical y-axis drawn on the RIGHT side (max — mid — 0 labels,
///    e.g. 60m / 30m / 0m), and
///  - tap-to-poke: tapping a bar pokes a small popup above that bar
///    showing its exact time (e.g. "1h 24m" or "45m"), which fades out
///    after a moment.
///
/// Float-style (not overflowing) — the popup anchors to the tapped bar
/// inside the chart's Stack, so scrolling/parent layout never breaks.
class HourlyBarChart extends StatefulWidget {
  const HourlyBarChart({
    super.key,
    required this.hourly,
    this.height = 120,
    this.axisTicks = const ['60m', '30m', '0m'],
  });

  final List<int> hourly;
  final double height;
  final List<String> axisTicks;

  @override
  State<HourlyBarChart> createState() => _HourlyBarChartState();
}

class _HourlyBarChartState extends State<HourlyBarChart> {
  int? _pokedHour;
  Timer? _pokeTimer;

  void _poke(int hour) {
    if (widget.hourly.isEmpty || hour >= widget.hourly.length) return;
    setState(() => _pokedHour = hour);
    _pokeTimer?.cancel();
    _pokeTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _pokedHour = null);
    });
  }

  @override
  void dispose() {
    _pokeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hourly = widget.hourly;
    final max = hourly.isEmpty ? 0 : hourly.reduce((a, b) => a > b ? a : b);
    final yMax = max > 0 ? ((max / 3600).ceil() * 3600).clamp(900, 3600) : 3600;
    final hasData = hourly.any((v) => v > 0);

    return SizedBox(
      height: widget.height,
      child: hasData
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Bars + tap-poke popups.
                Expanded(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // gridlines behind the bars
                      Positioned.fill(
                        child: Column(
                          children: [
                            for (var i = 0; i < 3; i++) ...[
                              Expanded(
                                child: Center(
                                  child: Container(
                                    height: 1,
                                    color: AppColors.stroke.withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Positioned.fill(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: List.generate(24, (h) {
                            final value = h < hourly.length ? hourly[h] : 0;
                            final normalized =
                                yMax == 0 ? 0.0 : (value / yMax).clamp(0.0, 1.0);
                            return Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                                child: GestureDetector(
                                  onTap: () => value > 0 ? _poke(h) : null,
                                  behavior: HitTestBehavior.opaque,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Align(
                                        alignment: Alignment.topCenter,
                                        child: _pokedHour == h
                                            ? _TooltipBubble(
                                                text: formatDurationShort(
                                                    Duration(seconds: value)),
                                              )
                                            : const SizedBox.shrink(),
                                      ),
                                      Container(
                                        height: (widget.height * 0.75) * normalized + 2,
                                        decoration: BoxDecoration(
                                          color: value > 0
                                              ? AppColors.ink
                                              : AppColors.surface2,
                                          borderRadius: const BorderRadius.vertical(
                                              top: Radius.circular(3)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                // Right-side y-axis: max — mid — 0
                const SizedBox(width: 6),
                SizedBox(
                  width: 34,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final tick in widget.axisTicks)
                        Text(tick,
                            style: TextStyle(fontSize: 9, color: AppColors.inkFaint)),
                    ],
                  ),
                ),
              ],
            )
          : Center(
              child: Text('No usage',
                  style: TextStyle(fontSize: 11.5, color: AppColors.inkFaint)),
            ),
    );
  }
}

/// Small poke popup: time + hour marker, anchored above the tapped bar.
/// Sized to its content (long "12h 59m" pill vs short "45m") and
/// centered over the bar so the bar itself never moves.
class _TooltipBubble extends StatelessWidget {
  const _TooltipBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return FractionalTranslation(
      translation: const Offset(0, -0.4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.ink,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Text(
          text,
          // Adaptive: font tracks the string length (longer values get a
          // slightly smaller run, never clipped).
          style: TextStyle(
            fontSize: text.length > 6 ? 11 : 12,
            color: AppColors.bg,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          softWrap: false,
        ),
      ),
    );
  }
}
