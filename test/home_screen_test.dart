import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ulimit/data/db/app_database.dart';
import 'package:ulimit/data/providers.dart';
import 'package:ulimit/features/home/home_screen.dart';

void main() {
  testWidgets('Home renders all sections without exceptions', (tester) async {
    // Tall viewport so every ListView section renders without scrolling —
    // the sections below the fold are exactly where the original
    // infinite-height crash lived.
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase.connect(NativeDatabase.memory());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          // Replace the 1-second ticking stream with a single value so
          // pumpAndSettle can actually settle (a periodic timer never
          // lets the frame queue go quiet).
          liveScreenTimeSecondsProvider.overrideWith((ref) => Stream.value(0)),
          // The 15s evaluation tick also schedules timers; a never-
          // completing empty stream keeps the test deterministic.
          evaluationTickProvider.overrideWith((ref) => Stream<void>.empty()),
        ],
        child: const MaterialApp(
          home: HomeScreen(),
        ),
      ),
    );

    // Let the DB streams emit and the UI rebuild. Explicit pumps only —
    // the overridden tickers emit synchronously, so no wall-clock waits
    // are needed and pumpAndSettle has nothing to stall on.
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Screen Time'), findsOneWidget);
    expect(find.text('Focus Time'), findsWidgets);
    expect(find.text('WEEKLY OVERVIEW'), findsOneWidget);
    expect(find.text('Screen time today'), findsOneWidget);
    expect(find.text('CONTROLS'), findsOneWidget);
    expect(find.text('Focus'), findsWidgets);

    await db.close();
  });
}
