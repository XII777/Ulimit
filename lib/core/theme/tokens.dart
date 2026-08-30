import 'package:flutter/material.dart';

/// Strict monochrome design system. Black / near-black / charcoal / gray
/// / white only — no accent hues anywhere in the app. State (active vs
/// inactive, selected vs not) is communicated through contrast and
/// weight, never color.
///
/// ## Theme switching
///
/// Colors are resolved from the ACTIVE PALETTE, not compile-time
/// constants — the app supports an AMOLED-dark and a monochrome-light
/// appearance plus a system-follow mode (see `AppColors.use` and the
/// `themeMode` setting). Because palette values are no longer
/// compile-time constants, widget constructors that reference
/// [AppColors] must not be `const`. [AppText] and [AppRadius] remain
/// numeric constants and are safe inside const expressions.
abstract final class AppColors {
  static AppPalette _current = darkPalette;

  /// The palette every [AppColors] getter resolves against. Synced from
  /// the user's Tile Appearance setting (and platform brightness in
  /// system mode) by the app root before the first frame and on change.
  static AppPalette get current => _current;

  static Brightness get brightness => _current.brightness;

  static void use(Brightness brightness) {
    _current = brightness == Brightness.light ? lightPalette : darkPalette;
  }

  static Color get bg => _current.bg;
  static Color get surface => _current.surface;
  static Color get surface2 => _current.surface2;
  static Color get stroke => _current.stroke;

  /// Primary text/icons. White in dark mode, black in light mode.
  static Color get ink => _current.ink;
  static Color get inkDim => _current.inkDim;
  static Color get inkFaint => _current.inkFaint;

  /// The single "active/selected/primary" tone across the whole app —
  /// buttons, active nav state, progress fills, chart lines. Deliberately
  /// just [ink] again: "active" is communicated by going *to* the
  /// strongest contrast, not by introducing a second hue.
  static Color get accent => _current.ink;
  static Color get accentSoft => _current.inkDim;

  /// Reserved for the blocking-overlay screen only.
  static Color get alert => _current.alert;
  static Color get danger => _current.danger;
}

/// One full monochrome palette.
class AppPalette {
  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color stroke;
  final Color ink;
  final Color inkDim;
  final Color inkFaint;
  final Color alert;
  final Color danger;

  const AppPalette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.stroke,
    required this.ink,
    required this.inkDim,
    required this.inkFaint,
    required this.alert,
    required this.danger,
  });
}

/// AMOLED dark: pure black foundation, near-black surfaces.
const AppPalette darkPalette = AppPalette(
  brightness: Brightness.dark,
  bg: Color(0xFF000000),
  surface: Color(0xFF0A0A0A),
  surface2: Color(0xFF111111),
  stroke: Color(0xFF222222),
  ink: Color(0xFFFFFFFF),
  inkDim: Color(0xFFAFAFAF),
  inkFaint: Color(0xFF666666),
  alert: Color(0xFFD9A441),
  danger: Color(0xFFC94F4F),
);

/// Monochrome light: white foundation, subtle gray surfaces.
const AppPalette lightPalette = AppPalette(
  brightness: Brightness.light,
  bg: Color(0xFFFFFFFF),
  surface: Color(0xFFFFFFFF),
  surface2: Color(0xFFF5F5F5),
  stroke: Color(0xFFE5E5E5),
  ink: Color(0xFF000000),
  inkDim: Color(0xFF666666),
  inkFaint: Color(0xFF999999),
  alert: Color(0xFF8A5A00),
  danger: Color(0xFF8A2A2A),
);

abstract final class AppRadius {
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 28.0;
  static const pill = 100.0;
}

/// Spacing scale — 4pt grid. Resist inventing one-off paddings; pick
/// from here so density stays consistent without a design review.
abstract final class AppSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Type scale — trimmed to Android Material guidelines rather than
/// marketing-mockup sizes. See learnui.design/android type scale.
abstract final class AppText {
  static const headline = 20.0; // screen titles (~H6)
  static const title = 16.0; // card / section titles (Subtitle1)
  static const body = 14.0; // body copy (Body2)
  static const caption = 12.0; // metadata, timestamps
  static const overline = 10.5; // eyebrow labels, letter-spaced
  static const hero = 38.0; // one-per-screen hero numbers only
}
