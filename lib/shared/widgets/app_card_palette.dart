import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Extracts the dominant/representative color from an app icon's PNG
/// bytes, then saturates it so the card has a strong visual identity —
/// the "icon expanded into a solid card" look.
///
/// Design constraints:
///  - Results are cached per package: decoding 200+ PNGs per list build
///    is wasteful, and `colorFor` is called on every card build.
///  - Uses the [InstantiableImageCodec] from dart:ui, so no new package
///    dependency and no plugin channel round-trips.
///  - Handles monochrome, near-black, near-white, transparent-only, and
///    tiny icons by falling back to a neutral mono tone.
class AppCardPalette {
  AppCardPalette._();

  static final Map<String, AppCardColor> _cache = {};

  /// Icon-derived color for [packageName]. Returns a cached value on
  /// subsequent calls. [bytes] must be the decoded icon PNG; null bytes
  /// (catalog missing the icon) short-circuits to the neutral fallback.
  static Future<AppCardColor> colorFor(
    String packageName,
    Uint8List? bytes,
  ) async {
    final cached = _cache[packageName];
    if (cached != null) return cached;

    final result = bytes == null
        ? AppCardColor.fallback()
        : await _extract(bytes);

    _cache[packageName] = result;
    return result;
  }

  /// Forget everything (test isolation / cache bloat).
  static void clear() => _cache.clear();

  static Future<AppCardColor> _extract(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        return _dominantFromImage(image);
      } finally {
        image.dispose();
      }
    } catch (_) {
      return AppCardColor.fallback();
    }
  }

  static Future<AppCardColor> _dominantFromImage(ui.Image image) async {
    // Sample a bounded grid — icons are 108–512px, full-pixel scan is
    // overkill and O(w*h) per icon on the first build only, but 512²
    // still costs ~1M reads on low-end hardware. Bound the scan to
    // 64×64 evenly-strided pixels (still covers all regions).
    final width = image.width;
    final height = image.height;
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

    if (bytes == null || width == 0 || height == 0) {
      return AppCardColor.fallback();
    }

    final strideX = math.max(1, width ~/ 64);
    final strideY = math.max(1, height ~/ 64);

    // Coarse hue buckets (16) × brightness (4) frequency map. A rounded
    // corner of white + a saturated glyph still picks the glyph if the
    // glyph covers enough sampled area; when the two tie, the more
    // saturated bucket wins (sort by count, then saturation).
    final counts = <int, int>{};
    final bucketColor = <int, Color>{};

    var samples = 0;
    double totalRed = 0, totalGreen = 0, totalBlue = 0;
    var opaqueSamples = 0;

    for (var y = 0; y < height; y += strideY) {
      for (var x = 0; x < width; x += strideX) {
        final idx = (y * width + x) * 4;
        final r = bytes.getUint8(idx);
        final g = bytes.getUint8(idx + 1);
        final b = bytes.getUint8(idx + 2);
        final a = bytes.getUint8(idx + 3);
        samples++;
        if (a < 40) continue;
        opaqueSamples++;
        totalRed += r;
        totalGreen += g;
        totalBlue += b;

        // Skip near-greyscale pixels: they carry no identity (white
        // backgrounds, grey shadows, black outlines) and would pollute
        // the dominant hue. Keep them as fallback evidence only.
        final maxC = math.max(r, math.max(g, b));
        final minC = math.min(r, math.min(g, b));
        final chroma = maxC - minC;
        if (chroma < 24) continue;

        final key = _bucketKey(r, g, b);
        counts[key] = (counts[key] ?? 0) + 1;
        bucketColor[key] ??= Color.fromARGB(255, r, g, b);
      }
    }

    if (samples == 0) {
      return AppCardColor.fallback();
    }

    // Transparent-only or fully grey icon → fall back to the average of
    // whatever pixels existed (won't be grey-only if any chroma exists).
    if (counts.isEmpty) {
      if (opaqueSamples == 0) return AppCardColor.fallback();
      final avg = Color.fromARGB(
        255,
        (totalRed / opaqueSamples).round(),
        (totalGreen / opaqueSamples).round(),
        (totalBlue / opaqueSamples).round(),
      );
      return _makeCardColor(avg);
    }

    // Pick the dominant bucket: most frequent, tie-broken by higher
    // saturation (a vivid glyph beats a big pale area on a 2:1 tie).
    var bestKey = 0;
    var bestCount = -1;
    var bestSaturation = -1.0;
    for (final entry in counts.entries) {
      final color = bucketColor[entry.key]!;
      final saturation = _saturation(color);
      if (entry.value > bestCount ||
          (entry.value == bestCount && saturation > bestSaturation)) {
        bestKey = entry.key;
        bestCount = entry.value;
        bestSaturation = saturation;
      }
    }

    return _makeCardColor(bucketColor[bestKey]!);
  }

  /// 16 hue buckets × 4 brightness buckets → a single int bucket key.
  static int _bucketKey(int r, int g, int b) {
    final hue = _hueIndex(r, g, b);
    final luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b).round();
    final brightness = (luminance * 4 ~/ 256).clamp(0, 3);
    return hue * 4 + brightness;
  }

  static int _hueIndex(int r, int g, int b) {
    // HSV hue → 16 buckets. Cheap approximations only: the goal is
    // grouping, not accurate hue math.
    final maxC = math.max(r, math.max(g, b)).toDouble();
    final minC = math.min(r, math.min(g, b)).toDouble();
    final delta = maxC - minC;
    if (delta == 0) return 0;
    var h = 0.0;
    if (maxC == r) {
      h = 60 * (((g - b) / delta) % 6);
    } else if (maxC == g) {
      h = 60 * (((b - r) / delta) + 2);
    } else {
      h = 60 * (((r - g) / delta) + 4);
    }
    if (h < 0) h += 360;
    return ((h / 360) * 16).floor().clamp(0, 15);
  }

  static double _saturation(Color c) {
    final r = c.r, g = c.g, b = c.b;
    final max = math.max(r, math.max(g, b));
    final min = math.min(r, math.min(g, b));
    if (max == 0) return 0;
    return (max - min) / max;
  }

  /// Builds a strong, saturated card color from the dominant pixel and
  /// balances it so white or dark text both work.
  static AppCardColor _makeCardColor(Color raw) {
    // Boost saturation up to ~72% (never pastel), keep the hue and
    // roughly the original lightness.
    final hsl = HSLColor.fromColor(raw);
    var sat = hsl.saturation;
    if (sat < 0.72) sat = 0.72;

    var lightness = hsl.lightness;
    if (lightness > 0.72) lightness = 0.72; // avoid near-white cards
    if (lightness < 0.22) lightness = 0.28; // avoid near-black cards
    final boosted = hsl.withSaturation(sat).withLightness(lightness).toColor();

    return AppCardColor(background: boosted, text: _contrastText(boosted));
  }

  /// WCAG-ish contrast pick: white on darker colors, near-black on
  /// light ones, with a brightness fallback for mid tones.
  static Color _contrastText(Color bg) {
    final luminance = bg.computeLuminance();
    // Threshold ~0.45: bright saturated colors (yellow/teal at 0.5+)
    // read better with dark text than with white.
    return luminance > 0.45 ? const Color(0xFF141414) : const Color(0xFFFFFFFF);
  }
}

/// The pair a card needs to render: solid background + readable text.
class AppCardColor {
  const AppCardColor({required this.background, required this.text});

  final Color background;
  final Color text;

  /// Neutral mono treatment for icons with no usable color (missing,
  /// monochrome, transparent, too dark, too light).
  factory AppCardColor.fallback() {
    return const AppCardColor(
      background: Color(0xFF2E3138),
      text: Color(0xFFFFFFFF),
    );
  }
}
