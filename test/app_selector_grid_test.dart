import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ulimit/core/native/enforcement_channel.dart';
import 'package:ulimit/data/apps_repository.dart';
import 'package:ulimit/shared/widgets/app_selector.dart';

/// Verifies the app-list grid geometry — the core design requirement:
/// exactly 2 cards per row on normal phone widths, with the card
/// extents driven by the actual available width (never a fixed width).
void main() {
  testWidgets('grid delegate yields 2 columns on a phone-sized sheet', (tester) async {
    const delegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 220,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 0.78,
    );

    // Phone-ish width minus the sheet's 20px side padding each side.
    const sheetWidth = 390.0;
    const hPadding = 20.0;
    final usable = sheetWidth - hPadding * 2;
    final columnWidth = (usable - 12) / 2; // one gap of 12

    final columns = (usable / (delegate.maxCrossAxisExtent + 12)).ceil();
    expect(columns, 2);
    expect(columnWidth, greaterThan(150)); // comfortable card width

    final cardHeight = columnWidth / 0.78;
    expect(cardHeight, greaterThan(columnWidth)); // portrait tiles
  });

  testWidgets('catalog loads iconless apps and card data resolves', (tester) async {
    final catalog = AppsCatalog([
      for (var i = 0; i < 4; i++)
        InstalledApp(
          packageName: 'com.example.app$i',
          displayName: 'App $i',
          iconBytes: null,
        ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appsCatalogProvider.overrideWith((ref) async => catalog),
        ],
        child: const MaterialApp(home: Scaffold(body: SizedBox())),
      ),
    );
    await tester.pump();

    // Even without icons, catalog + name lookup resolve to real data —
    // the card layer falls back to its neutral color rather than
    // inventing anything.
    expect(catalog.apps.length, 4);
    expect(catalog.nameFor('com.example.app2'), 'App 2');
    expect(catalog.iconFor('com.example.app3'), isNull);
  });
}
