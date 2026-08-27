import 'package:flutter/material.dart';

/// Design tokens. One accent color, used everywhere, per the design
/// direction — the only intentional exception is [AppColors.alert],
/// reserved exclusively for the blocking-overlay / invincible-lock
/// screens where a second color is load-bearing for safety, not decor.
abstract final class AppColors {
  static const bg = Color(0xFF0F1116);
  static const surface = Color(0xFF1A1D25);
  static const surface2 = Color(0xFF22262F);
  static const stroke = Color(0xFF2C303A);

  static const ink = Color(0xFFF2F1EC);
  static const inkDim = Color(0xFF9497A3);
  static const inkFaint = Color(0xFF5C606C);

  /// The single accent. Every ring, bar, badge, and highlight in the
  /// app uses this — do not introduce a second "brand" color.
  static const accent = Color(0xFF8B7FE8);
  static const accentSoft = Color(0xFFB7AEF5);

  /// Reserved for blocking-overlay screens only.
  static const alert = Color(0xFFF2A94D);
  static const danger = Color(0xFFE8697A);
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
