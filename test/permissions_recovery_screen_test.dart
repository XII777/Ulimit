import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ulimit/data/permissions_providers.dart';
import 'package:ulimit/features/onboarding/permissions_recovery_screen.dart';

void main() {
  testWidgets('recovery screen shows only missing permissions', (tester) async {
    // No native access here: every permission reads false — an app
    // updated by Android behaves exactly like this (grants re-claimed).
    await tester.pumpWidget(
      ProviderScope(
        child: const MaterialApp(
          home: PermissionsRecoveryScreen(onReEnabled: _noop),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ulimit updated — access was reset'), findsOneWidget);
    // The three required permission cards, not the full wizard.
    expect(find.text('Accessibility'), findsOneWidget);
    expect(find.text('Notification Access'), findsOneWidget);
    expect(find.text('VPN & Network'), findsOneWidget);
    // Optional permissions are not shown (biometric / device admin).
    expect(find.text('Biometrics'), findsNothing);
    expect(find.text('Device Admin'), findsNothing);
    // Continue is disabled while something is missing.
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNotNull); // "Re-enable to continue" refreshes
  });

  testWidgets('recovery screen shows all access restored and enables Continue',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Everything already granted — nothing to re-enable.
          accessibilityEnabledProvider.overrideWith((ref) async => true),
          vpnPermissionGrantedProvider.overrideWith((ref) async => true),
          notificationListenerEnabledProvider.overrideWith((ref) async => true),
          postNotificationsGrantedProvider.overrideWith((ref) async => true),
          usageAccessGrantedProvider.overrideWith((ref) async => true),
        ],
        child: const MaterialApp(
          home: PermissionsRecoveryScreen(onReEnabled: _noop),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('All access restored'), findsOneWidget);
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNotNull);
  });
}

void _noop() {}
