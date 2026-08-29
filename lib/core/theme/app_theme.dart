import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'tokens.dart';

final class AppTheme {
  AppTheme._();

  static ThemeData get dark {
    final display = GoogleFonts.spaceGrotesk();
    final body = GoogleFonts.inter();

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bg,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.ink,
        secondary: AppColors.inkDim,
        surface: AppColors.surface,
        error: AppColors.danger,
      ),
      // Switch: white thumb on off-white track when active, dark when off.
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? AppColors.bg : AppColors.inkFaint),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? AppColors.ink : AppColors.surface2),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.ink,
        inactiveTrackColor: AppColors.stroke,
        thumbColor: AppColors.ink,
        overlayColor: AppColors.ink.withOpacity(0.12),
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
          color: AppColors.inkDim,
        ),
        labelSmall: body.copyWith(
          fontSize: AppText.overline,
          color: AppColors.inkFaint,
          letterSpacing: 0.6,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.ink,
        elevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
        titleTextStyle: display.copyWith(
          fontSize: AppText.headline,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
      ),
      dividerColor: AppColors.stroke,
      cardColor: AppColors.surface,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
  }
}
