import 'package:flutter/material.dart';

/// Strict monochrome design system. Black / near-black / charcoal / gray
/// / white only — no accent hues anywhere in the app. State (active vs
/// inactive, selected vs not) is communicated through contrast and
/// weight, never color.
///
/// [alert] and [danger] are the one deliberate, narrow exception: they
/// exist only for the blocking-overlay / Invincible-Mode-locked screen
/// (not yet built in Flutter as of this token change). That screen is a
/// hard stop the person can't act through — distinguishing it from
/// every other screen by more than contrast is a safety consideration,
/// not a decorative one. They are not referenced anywhere else in the
/// app; if that ever changes, it's a bug against this design system.
abstract final class AppColors {
  static const bg = Color(0xFF0A0A0B);
  static const surface = Color(0xFF16171A);
  static const surface2 = Color(0xFF1F2023);
  static const stroke = Color(0x1FFFFFFF); // subtle low-opacity white border

  static const ink = Color(0xFFF5F5F4); // primary text/icons — near-white
  static const inkDim = Color(0xFFA3A3A6); // secondary text — medium gray
  static const inkFaint = Color(0xFF6B6B6F); // disabled/tertiary — dark gray

  /// The single "active/selected/primary" tone across the whole app —
  /// buttons, active nav state, progress fills, chart lines. Deliberately
  /// just [ink] again: "active" is communicated by going *to* white, not
  /// by introducing a second hue.
  static const accent = ink;
  static const accentSoft = inkDim;

  /// Reserved for the blocking-overlay screen only — see class doc.
  static const alert = Color(0xFFD9A441);
  static const danger = Color(0xFFC94F4F);
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
