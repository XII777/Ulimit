import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'tokens.dart';

final class AppTheme {
  AppTheme._();

  static ThemeData get dark {
    // google_fonts caches the font file after first load, so this isn't
    // a per-frame network/asset hit — it resolves once and every
    // TextStyle below is a cheap copyWith.
    final display = GoogleFonts.spaceGrotesk();
    final body = GoogleFonts.inter();

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bg,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accent,
        secondary: AppColors.accent,
        surface: AppColors.surface,
        error: AppColors.danger,
      ),
      textTheme: TextTheme(
        headlineSmall: display.copyWith(
          fontSize: AppText.headline,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
          letterSpacing: -0.2,
        ),
        titleMedium: body.copyWith(
          fontSize: AppText.title,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
        bodyMedium: body.copyWith(
          fontSize: AppText.body,
          color: AppColors.ink,
        ),
        bodySmall: body.copyWith(
          fontSize: AppText.caption,
          color: AppColors.inkFaint,
        ),
        labelSmall: body.copyWith(
          fontSize: AppText.overline,
          color: AppColors.inkFaint,
          letterSpacing: 0.6,
        ),
      ),
      // Disable the default Material ripple splash flare on our custom
      // pill buttons/cards; we handle press feedback ourselves with
      // AnimatedScale so it stays consistent with the morph transitions
      // elsewhere instead of two different motion languages fighting.
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
  }
}
