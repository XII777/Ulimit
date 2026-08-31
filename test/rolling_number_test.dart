import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ulimit/shared/widgets/rolling_number.dart';

void main() {
  testWidgets('RollingNumber slot height fits full glyphs for long durations', (tester) async {
    const style = TextStyle(
        fontSize: 16, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]);

    // The longest realistic duration ("12h 59m 59s"). The previous
    // fontSize * 1.5 heuristic clipped the top/bottom of digits on
    // Inter; the slot must now be tall enough for the full glyphs.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RollingNumber(text: '12h 59m 59s', style: style),
          ),
        ),
      ),
    );

    final text = tester.widget<Text>(find.byType(Text).first);
    final effective = DefaultTextStyle.of(tester.element(find.byType(RollingNumber)))
        .style
        .merge(style);

    final painter = TextPainter(
      text: TextSpan(text: '0', style: effective),
      textDirection: TextDirection.ltr,
    )..layout();

    final slot = tester.renderObject<RenderBox>(find.byType(RollingNumber));
    // The row's height is the per-char slot height; it must be at least
    // the measured line height so ClipRect never trims the glyphs.
    expect(slot.size.height, greaterThanOrEqualTo(painter.height));

    // And every character must have been laid out (no overflow errors).
    expect(tester.takeException(), isNull);
  });

  testWidgets('RollingNumber renders 0m without clipping', (tester) async {
    const style = TextStyle(fontSize: 16, fontWeight: FontWeight.w700);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: RollingNumber(text: '0m', style: style)),
        ),
      ),
    );

    // Each character is its own Text inside the animated slot.
    expect(find.text('0'), findsWidgets);
    expect(find.text('m'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
