import 'package:flutter/material.dart';

/// Design tokens. The ring/bar/badge language communicates state through
/// exactly three colors — pick one of these, never an ad-hoc color:
///   - [accent] (violet) — the primary brand color: focus sessions, chart
///     lines, anything that isn't a live "budget state" signal.
///   - [calm] (teal) — on track / plenty of budget left.
///   - [alert] (amber) — near your limit, AND the blocking-overlay /
///     invincible-lock state. One color for both on purpose: a live
///     warning ring and the overlay it leads to are the same state,
///     not two different ones.
abstract final class AppColors {
  static const bg = Color(0xFF0F1116);
  static const surface = Color(0xFF1A1D25);
  static const surface2 = Color(0xFF22262F);
  static const stroke = Color(0xFF2C303A);

  static const ink = Color(0xFFF2F1EC);
  static const inkDim = Color(0xFF9497A3);
  static const inkFaint = Color(0xFF5C606C);

  /// Primary brand accent.
  static const accent = Color(0xFF8B7FE8);
  static const accentSoft = Color(0xFFB7AEF5);

  /// On-track / plenty-of-budget ring & badge state.
  static const calm = Color(0xFF5FC9AE);

  /// Near-limit warning AND blocking-overlay / invincible-lock state.
  static const alert = Color(0xFFF2A94D);
  static const danger = Color(0xFFE8697A);

  /// Home screen's gamified progress/trend colors — deliberately scoped
  /// to Home only (per that screen's specific design brief), not a
  /// replacement for [accent] elsewhere in the app. Comparable
  /// saturation/intensity by design: green and red should read as
  /// equally vivid opposites, not "vivid positive, muted negative."
  static const homeLime = Color(0xFFAEFF00);
  static const homeNegative = Color(0xFFFF3B3B);
}

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
