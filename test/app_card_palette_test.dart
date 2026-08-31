import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ulimit/shared/widgets/app_card_palette.dart';

/// Encodes a solid RGBA image to PNG using dart:ui's codec — the same
/// pipeline the catalog uses (Image.memory decodes it later).
Future<Uint8List> _solidPng(int r, int g, int b, {int w = 64, int h = 64}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = ui.Color.fromARGB(255, r, g, b),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return byteData!.buffer.asUint8List();
}

void main() {
  testWidgets('colorFor extracts a saturated dominant color from a PNG', (tester) async {
    AppCardPalette.clear();
    final red = await tester.runAsync(() => _solidPng(0xE5, 0x48, 0x4D));
    expect(red, isNotNull);

    final color = await tester.runAsync(() => AppCardPalette.colorFor('com.example.red', red));
    expect(color, isNotNull);
    // Red icon → strongly saturated warm card, clearly red-dominant.
    expect(color!.background.r, greaterThan(color.background.b + 0.2));
    expect(color.background.computeLuminance(), lessThan(0.45));
    expect(color.text, const Color(0xFFFFFFFF));
    AppCardPalette.clear();
  });

  testWidgets('colorFor falls back to the neutral tone for null bytes', (tester) async {
    AppCardPalette.clear();
    final fallback = await tester.runAsync(() => AppCardPalette.colorFor('com.example.missing', null));
    expect(fallback!.background, const Color(0xFF2E3138));
    expect(fallback.text, const Color(0xFFFFFFFF));
    AppCardPalette.clear();
  });

  testWidgets('cache dedupes repeated colorFor calls', (tester) async {
    AppCardPalette.clear();
    final first = await tester.runAsync(() => AppCardPalette.colorFor('com.example.cached', null));
    final second = await tester.runAsync(() => AppCardPalette.colorFor('com.example.cached', null));
    expect(identical(first, second), isTrue);
    AppCardPalette.clear();
  });
}
