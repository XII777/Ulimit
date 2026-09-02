import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rolling_text/rolling_text.dart';

void main() {
  testWidgets('RollingText renders the longest realistic duration without exceptions',
      (tester) async {
    const style = TextStyle(
        fontSize: 16, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]);

    // "12h 59m 59s" — the widest duration shown in the app. The package
    // owns the per-slot clipping; we just guard that our usage renders.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: RollingText(text: '12h 59m 59s', style: style)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RollingText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RollingText rolls to a new value without throwing', (tester) async {
    const style = TextStyle(fontSize: 16, fontWeight: FontWeight.w700);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: RollingText(text: '0m', style: style))),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Changing the text re-rolls; only the changed character animates.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: RollingText(text: '1m', style: style))),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
