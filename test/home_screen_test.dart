import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ulimit/data/db/app_database.dart';
import 'package:ulimit/data/providers.dart';
import 'package:ulimit/features/home/home_screen.dart';

void main() {
  testWidgets('Home renders all sections without exceptions', (tester) async {
    final db = AppDatabase.connect(NativeDatabase.memory());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
        ],
        child: const MaterialApp(
          home: HomeScreen(),
        ),
      ),
    );

    // Let all the DB streams emit and the UI settle.
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.text('Screen Time'), findsOneWidget);
    expect(find.text('Focus Time'), findsWidgets);
    expect(find.text("TODAY'S OVERVIEW"), findsOneWidget);
    expect(find.text('Average daily screen time'), findsOneWidget);
    expect(find.text('CONTROLS'), findsOneWidget);
    expect(find.text('Focus'), findsWidgets);

    await db.close();
  });
}
