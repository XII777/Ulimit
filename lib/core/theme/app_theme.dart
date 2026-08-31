import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'tokens.dart';

final class AppTheme {
  AppTheme._();

  /// AMOLED dark: pure black scaffold, near-black surfaces, white ink.
  static ThemeData get dark => _build(darkPalette);

  /// Monochrome light: white scaffold, subtle gray surfaces, black ink.
  static ThemeData get light => _build(lightPalette);

  static ThemeData _build(AppPalette c) {
    final display = GoogleFonts.spaceGrotesk();
    final body = GoogleFonts.inter();
    final dark = c.brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      brightness: c.brightness,
      scaffoldBackgroundColor: c.bg,
      colorScheme: ColorScheme(
        brightness: c.brightness,
        primary: c.ink,
        onPrimary: c.bg,
        secondary: c.inkDim,
        onSecondary: c.bg,
        surface: c.surface,
        onSurface: c.ink,
        error: c.danger,
        onError: c.bg,
      ),
      // Switch: strong-contrast thumb when active, muted when off.
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.bg : c.inkFaint),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.ink : c.surface2),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: c.ink,
        inactiveTrackColor: c.stroke,
        thumbColor: c.ink,
        overlayColor: c.ink.withValues(alpha: 0.12),
      ),
      textTheme: TextTheme(
        headlineSmall: display.copyWith(
          fontSize: AppText.headline,
          fontWeight: FontWeight.w600,
          color: c.ink,
          letterSpacing: -0.2,
        ),
        titleMedium: body.copyWith(
          fontSize: AppText.title,
          fontWeight: FontWeight.w600,
          color: c.ink,
        ),
        bodyMedium: body.copyWith(
          fontSize: AppText.body,
          color: c.ink,
        ),
        bodySmall: body.copyWith(
          fontSize: AppText.caption,
          color: c.inkDim,
        ),
        labelSmall: body.copyWith(
          fontSize: AppText.overline,
          color: c.inkFaint,
          letterSpacing: 0.6,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        foregroundColor: c.ink,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          // White icons on dark backgrounds, black on light.
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        ),
        titleTextStyle: display.copyWith(
          fontSize: AppText.headline,
          fontWeight: FontWeight.w600,
          color: c.ink,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.bg,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
        ),
      ),
      // iOS-fidelity motion: Cupertino slide + parallax on push/pop
      // (300ms easeOutCubic, swipe-back gesture), with the fade-up
      // replacement on Android dialogs/context menus. One theme set for
      // both light and dark so transitions never change mid-navigation.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        },
      ),
      // iOS scroll feel everywhere defaults: bounce at the edges, and
      // the slower-than-Android deceleration that makes lists glide
      // rather than snap. Scrollables that opt into springScrollPhysics
      // still override this per-widget.
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStatePropertyAll(3.0),
        radius: const Radius.circular(999),
        thumbColor: WidgetStatePropertyAll(c.inkFaint.withValues(alpha: 0.4)),
      ),
      dividerColor: c.stroke,
      cardColor: c.surface,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
  }
}
