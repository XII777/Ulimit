import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// 24-bar hourly usage chart with a vertical y-axis drawn on the RIGHT
/// side (max — mid — 0 labels, e.g. 60m / 30m / 0m). Plain bars, no
/// interactive tooltips — taps are reserved for other UI.
class HourlyBarChart extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final max = hourly.isEmpty ? 0 : hourly.reduce((a, b) => a > b ? a : b);
    final yMax = max > 0 ? ((max / 3600).ceil() * 3600).clamp(900, 3600) : 3600;
    final hasData = hourly.any((v) => v > 0);

    return SizedBox(
      height: height,
      child: hasData
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Bars over subtle gridlines.
                Expanded(
                  child: Stack(
                    children: [
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
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Container(
                                      height: (height * 0.75) * normalized + 2,
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
                      for (final tick in axisTicks)
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
