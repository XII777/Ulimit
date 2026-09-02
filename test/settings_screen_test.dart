import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:ulimit/data/db/app_database.dart';
import 'package:ulimit/data/permissions_providers.dart';
import 'package:ulimit/data/providers.dart';
import 'package:ulimit/features/settings/settings_screen.dart';

void main() {
  late GoRouter router;
  late AppDatabase db;

  Future<void> pump(WidgetTester tester) async {
    db = AppDatabase.connect(NativeDatabase.memory());
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const Scaffold(body: SettingsScreen()),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          // Channel-backed permission list is irrelevant here.
          allPermissionsProvider.overrideWith((ref) => const <PermissionStatus>[]),
        ],
        child: MaterialApp.router(
          routerDelegate: router.routerDelegate,
          routeInformationProvider: router.routeInformationProvider,
          routeInformationParser: router.routeInformationParser,
        ),
      ),
    );
    await tester.pumpAndSettle();

    router.go('/settings');
    await tester.pumpAndSettle();
  }

  testWidgets('sections start fully collapsed', (tester) async {
    await pump(tester);

    for (final label in ['GENERAL', 'FOCUS', 'PERMISSIONS', 'DATA', 'ABOUT']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Tile Appearance'), findsNothing);
    expect(find.text('Export data'), findsNothing);

    // Close the DB in-body (before teardown) so drift's stream teardown
    // timer doesn't leak into the pending-timer check.
    await db.close();
  });

  testWidgets('tapping a section expands it and collapses the previous',
      (tester) async {
    await pump(tester);

    await tester.tap(find.text('GENERAL'));
    await tester.pumpAndSettle();
    expect(find.text('Tile Appearance'), findsOneWidget);

    await tester.tap(find.text('DATA'));
    await tester.pumpAndSettle();
    expect(find.text('Tile Appearance'), findsNothing);
    expect(find.text('Export data'), findsOneWidget);

    await db.close();
  });

  testWidgets('tapping the open section again collapses it', (tester) async {
    await pump(tester);

    await tester.tap(find.text('DATA'));
    await tester.pumpAndSettle();
    expect(find.text('Export data'), findsOneWidget);

    await tester.tap(find.text('DATA'));
    await tester.pumpAndSettle();
    expect(find.text('Export data'), findsNothing);

    await db.close();
  });

  testWidgets('leaving Settings and returning collapses everything',
      (tester) async {
    await pump(tester);

    await tester.tap(find.text('GENERAL'));
    await tester.pumpAndSettle();
    expect(find.text('Tile Appearance'), findsOneWidget);

    router.go('/');
    await tester.pumpAndSettle();
    router.go('/settings');
    await tester.pumpAndSettle();

    expect(find.text('Tile Appearance'), findsNothing);
    expect(find.text('Export data'), findsNothing);

    await db.close();
  });
}
