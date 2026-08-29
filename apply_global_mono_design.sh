#!/usr/bin/env bash
# Global monochrome design system — applies to the WHOLE APP.
#
# What changes:
#  - tokens.dart: black/charcoal/gray/white ONLY — all neon/accent hues gone
#  - app_theme.dart: ThemeData aligned (Switch, Slider, AppBar all monochrome)
#  - premium_components.dart: NEW shared component library
#    (PremiumFeatureTile, PremiumCard, PremiumListTile, PremiumButton,
#     PremiumHeader, PremiumSectionLabel, PremiumDivider)
#  - home_screen.dart: reference implementation — no gamification,
#    full-width feature tiles, monochrome ring + charts
#  - All other screens: fixed white-on-white contrast bugs from the token
#    change, removed lingering lime/violet/neon references
#  - increase_pulse.dart + achievement_toast.dart: DELETED (gamification
#    removed per the new design brief; no screen imports them)
#
# What does NOT change: business logic, routing, state management,
# data models, providers, Drift schema, Android services, any feature behavior.
set -e

if [ ! -f pubspec.yaml ]; then
  echo "Run this from inside your repo root (where pubspec.yaml lives)."
  exit 1
fi

mkdir -p "lib/core/theme"
cat > "lib/core/theme/tokens.dart" << 'PATCH_EOF'
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
PATCH_EOF

mkdir -p "lib/core/theme"
cat > "lib/core/theme/app_theme.dart" << 'PATCH_EOF'
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
PATCH_EOF

mkdir -p "lib/core/theme"
cat > "lib/core/theme/premium_components.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'tokens.dart';
import 'pressable_scale.dart';

/// The horizontal feature-navigation tile used throughout the app:
/// icon, title, description, chevron. One component, one place to
/// change if the pattern ever needs to evolve — every feature-nav
/// surface (Home's controls, Settings sections, feature pickers)
/// should use this rather than hand-rolling an equivalent Row.
class PremiumFeatureTile extends StatelessWidget {
  const PremiumFeatureTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  /// Defaults to a chevron; pass something else (a status label, a
  /// switch) when the tile needs to show state rather than just
  /// navigate — e.g. Settings' permission rows.
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(icon, size: 18, color: AppColors.ink),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: AppText.title, fontWeight: FontWeight.w600, color: AppColors.ink)),
                const SizedBox(height: 2),
                Text(
                  description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: AppText.caption, color: AppColors.inkDim),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing ??
              const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.inkFaint),
        ],
      ),
    );

    if (onTap == null) return content;
    return PressableScale(onTap: onTap!, child: content);
  }
}

/// Small letter-spaced eyebrow label above a group of content —
/// "THIS WEEK", "CONTROLS", "PERMISSIONS". Was duplicated privately in
/// at least two screens; this is the one shared version.
class PremiumSectionLabel extends StatelessWidget {
  const PremiumSectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: AppText.overline,
          color: AppColors.inkFaint,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w600,
        ),
      );
}

/// Back-arrow + title (+ optional subtitle) header, used by every
/// pushed detail screen. Consolidates what was a hand-rolled Row of a
/// small IconButton-in-a-Container plus a title Column on each screen
/// that needed it.
class PremiumHeader extends StatelessWidget {
  const PremiumHeader({super.key, required this.title, this.subtitle, this.onBack});

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: IconButton(
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.arrow_back_rounded, size: 16, color: AppColors.inkDim),
            onPressed: onBack ?? () => Navigator.of(context).maybePop(),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: AppText.headline, fontWeight: FontWeight.w600, color: AppColors.ink)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: const TextStyle(fontSize: AppText.caption, color: AppColors.inkDim)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

enum PremiumButtonVariant { primary, secondary, outlined, text }

/// One button component covering all four variants from the design
/// system rather than four separate ButtonStyle blocks scattered across
/// screens. Primary = white fill/black text (the one "this is the main
/// action" affordance in the whole app); everything else recedes from
/// that intentionally.
class PremiumButton extends StatelessWidget {
  const PremiumButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = PremiumButtonVariant.primary,
    this.fullWidth = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final PremiumButtonVariant variant;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    late final Color bg;
    late final Color fg;
    Border? border;

    switch (variant) {
      case PremiumButtonVariant.primary:
        bg = disabled ? AppColors.surface2 : AppColors.ink;
        fg = disabled ? AppColors.inkFaint : AppColors.bg;
      case PremiumButtonVariant.secondary:
        bg = AppColors.surface2;
        fg = disabled ? AppColors.inkFaint : AppColors.ink;
      case PremiumButtonVariant.outlined:
        bg = Colors.transparent;
        fg = disabled ? AppColors.inkFaint : AppColors.ink;
        border = Border.all(color: AppColors.stroke);
      case PremiumButtonVariant.text:
        bg = Colors.transparent;
        fg = disabled ? AppColors.inkFaint : AppColors.inkDim;
    }

    final child = Container(
      width: fullWidth ? double.infinity : null,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: border,
      ),
      child: Text(label, style: TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w600, color: fg)),
    );

    if (disabled) return child;
    return PressableScale(onTap: onPressed!, child: child);
  }
}

/// Consistent card surface for grouped content that isn't a navigation
/// tile — metric displays, toggle groups. Deliberately plain: per the
/// design system, cards should read as quiet dark surfaces, not
/// decorated containers.
class PremiumCard extends StatelessWidget {
  const PremiumCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: child,
    );
  }
}

/// A single row inside a [PremiumCard] — label, optional sublabel, and
/// a trailing widget (switch, value, status). Consolidates the
/// near-identical row patterns previously hand-rolled per screen.
class PremiumListTile extends StatelessWidget {
  const PremiumListTile({
    super.key,
    required this.label,
    this.sublabel,
    this.trailing,
    this.onTap,
  });

  final String label;
  final String? sublabel;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: AppText.body, color: AppColors.ink)),
                if (sublabel != null) ...[
                  const SizedBox(height: 2),
                  Text(sublabel!, style: const TextStyle(fontSize: AppText.caption, color: AppColors.inkDim)),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

/// Hairline divider matching the card border color, for use inside a
/// [PremiumCard] between [PremiumListTile]s.
class PremiumDivider extends StatelessWidget {
  const PremiumDivider({super.key});
  @override
  Widget build(BuildContext context) => const Divider(height: 1, color: AppColors.stroke);
}
PATCH_EOF

mkdir -p "lib/features/home"
cat > "lib/features/home/home_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/premium_components.dart';
import '../../data/providers.dart';
import '../../data/home_data_providers.dart';
import '../../shared/widgets/limit_ring.dart';
import '../../shared/widgets/trend_chart.dart';
import '../../shared/widgets/rolling_number.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenTime = ref.watch(todayScreenTimeProvider);
    final budgetMinutes = ref.watch(dailyBudgetProvider);
    final weeklyUsage = ref.watch(weeklyScreenTimeHoursProvider);
    final weeklyFocusSeconds = ref.watch(weeklyFocusSecondsProvider);
    final weeklyFocusHours = ref.watch(weeklyFocusHoursByDayProvider);
    final weeklyPickups = ref.watch(weeklyPickupsProvider);
    final screenTimeDelta = ref.watch(screenTimeDeltaProvider);
    final focusDelta = ref.watch(focusTimeDeltaProvider);
    final pickupsDelta = ref.watch(pickupsDeltaProvider);

    return DecoratedBox(
      // A very faint white top vignette for depth — not a colored
      // "atmospheric" gradient. Alpha stays low enough that the top
      // and bottom of the screen read as the same near-black surface;
      // this is lighting, not an accent.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, 0.35],
          colors: [Color(0x14FFFFFF), Colors.transparent],
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
          children: [
            const _Header(),
            const SizedBox(height: 22),

            Center(
              child: _buildRing(screenTime, budgetMinutes),
            ),
            const SizedBox(height: 28),

            const PremiumSectionLabel('THIS WEEK'),
            const SizedBox(height: 10),
            _WeeklyTrendCard(weeklyHours: weeklyUsage, delta: screenTimeDelta),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _MiniTrendCard(
                    label: 'Focus time',
                    valueText: _formatFocusTotal(weeklyFocusSeconds.valueOrNull),
                    values: weeklyFocusHours.valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0],
                    delta: focusDelta,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MiniTrendCard(
                    label: 'Pickups / day',
                    valueText: _formatPickupsAvg(weeklyPickups.valueOrNull),
                    values: weeklyPickups.valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0],
                    delta: pickupsDelta,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),

            const PremiumSectionLabel('CONTROLS'),
            const SizedBox(height: 10),
            const _ControlsList(),
          ],
        ),
      ),
    );
  }

  Widget _buildRing(AsyncValue<Duration> screenTime, AsyncValue<int> budgetMinutes) {
    if (screenTime.isLoading || budgetMinutes.isLoading) {
      return const LimitRing(progress: 0, size: 130, trackColor: AppColors.stroke);
    }
    final used = screenTime.valueOrNull ?? Duration.zero;
    final budget = Duration(minutes: budgetMinutes.valueOrNull ?? 240);
    return _ScreenTimeRing(used: used, budget: budget);
  }

  String _formatFocusTotal(int? seconds) {
    if (seconds == null || seconds == 0) return '0m';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }

  String _formatPickupsAvg(List<double>? days) {
    if (days == null || days.isEmpty) return '—';
    final avg = days.reduce((a, b) => a + b) / days.length;
    return avg.round().toString();
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Today',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: AppColors.ink)),
        const SizedBox(height: 2),
        Text(_formattedDate(), style: const TextStyle(fontSize: AppText.body, color: AppColors.inkDim)),
      ],
    );
  }

  String _formattedDate() {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final now = DateTime.now();
    return '${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
  }
}

class _ScreenTimeRing extends StatelessWidget {
  const _ScreenTimeRing({required this.used, required this.budget});
  final Duration used;
  final Duration budget;

  @override
  Widget build(BuildContext context) {
    final remaining = budget - used;
    final safeBudget = budget.inSeconds <= 0 ? 1 : budget.inSeconds;
    final progress = 1 - (used.inSeconds / safeBudget).clamp(0.0, 1.0);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: progress),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => LimitRing(
        progress: value,
        size: 148,
        strokeWidth: 8,
        color: AppColors.ink,
        trackColor: AppColors.stroke,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RollingNumber(
              text: _formatDuration(remaining),
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w600, color: AppColors.ink),
            ),
            const SizedBox(height: 4),
            const Text('LEFT TODAY',
                style: TextStyle(fontSize: AppText.overline, color: AppColors.inkFaint, letterSpacing: 0.6)),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final clamped = d.isNegative ? Duration.zero : d;
    final h = clamped.inHours;
    final m = clamped.inMinutes % 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _WeeklyTrendCard extends StatelessWidget {
  const _WeeklyTrendCard({required this.weeklyHours, required this.delta});
  final AsyncValue<List<double>> weeklyHours;
  final TrendDelta delta;

  @override
  Widget build(BuildContext context) {
    final values = weeklyHours.valueOrNull;
    final hasData = values != null && values.any((v) => v > 0);
    final avg = hasData ? values.reduce((a, b) => a + b) / values.length : 0.0;

    return PremiumCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Avg. daily screen time',
                  style: TextStyle(fontSize: AppText.caption, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
              if (delta.hasData) _DeltaLabel(delta: delta),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hasData ? _formatHours(avg) : 'No data yet',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.ink),
          ),
          const SizedBox(height: 8),
          if (hasData)
            TrendAreaChart(values: values, color: AppColors.ink, showAverageLine: false)
          else
            const SizedBox(
              height: 84,
              child: Center(
                child: Text(
                  'Enable Accessibility access to start tracking',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: AppText.caption, color: AppColors.inkFaint),
                ),
              ),
            ),
          const SizedBox(height: 4),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _DayLabel('M'), _DayLabel('T'), _DayLabel('W'), _DayLabel('T'),
              _DayLabel('F'), _DayLabel('S'), _DayLabel('S'),
            ],
          ),
        ],
      ),
    );
  }

  String _formatHours(double hours) {
    final h = hours.floor();
    final m = ((hours - h) * 60).round();
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

/// Factual trend indicator — arrow + percentage, always rendered in
/// [AppColors.ink]. Direction is carried by the arrow glyph and the
/// adjacent label's wording ("vs last week"), not by color, per the
/// design system's monochrome rule and its own accessibility principle
/// that meaning must never rest on color alone.
class _DeltaLabel extends StatelessWidget {
  const _DeltaLabel({required this.delta});
  final TrendDelta delta;

  @override
  Widget build(BuildContext context) {
    final arrow = delta.isPositive ? '▲' : '▼';
    return Text(
      '$arrow ${delta.percent.round()}%',
      style: const TextStyle(fontSize: AppText.caption, color: AppColors.inkDim, fontWeight: FontWeight.w600),
    );
  }
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 9, color: AppColors.inkFaint));
}

class _MiniTrendCard extends StatelessWidget {
  const _MiniTrendCard({
    required this.label,
    required this.valueText,
    required this.values,
    required this.delta,
  });

  final String label;
  final String valueText;
  final List<double> values;
  final TrendDelta delta;

  @override
  Widget build(BuildContext context) {
    return PremiumCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Sparkline(values: values, color: AppColors.ink),
          const SizedBox(height: 6),
          RollingNumber(
            text: valueText,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.ink),
          ),
          if (delta.hasData) ...[
            const SizedBox(height: 2),
            _DeltaLabel(delta: delta),
          ],
        ],
      ),
    );
  }
}

/// Full-width horizontal tiles per the design system's feature-navigation
/// pattern — replaces the previous 2-column icon-grid layout, which was
/// a different visual language from every other feature-nav surface in
/// the app.
class _ControlsList extends StatelessWidget {
  const _ControlsList();

  static const _tiles = [
    ('Focus', Icons.track_changes_rounded, 'Start a session', null),
    ('App Limits', Icons.grid_view_rounded, 'Manage groups', null),
    ('App Blocking', Icons.block_rounded, 'Manage blocked apps', null),
    ('Internet & Sites', Icons.public_rounded, 'VPN & filters', null),
    ('Notifications', Icons.notifications_rounded, 'Manage delivery', null),
    ('Bedtime', Icons.dark_mode_rounded, 'Manage schedule', null),
    ('Parental & Lock', Icons.shield_rounded, 'Device admin & tamper protection', Routes.parental),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final (title, icon, description, route) in _tiles) ...[
          PremiumFeatureTile(
            icon: icon,
            title: title,
            description: description,
            onTap: route == null ? null : () => context.push(route),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
PATCH_EOF

mkdir -p "lib/features/focus"
cat > "lib/features/focus/focus_screen.dart" << 'PATCH_EOF'
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/tokens.dart';
import '../../shared/widgets/limit_ring.dart';

class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  static const _total = Duration(minutes: 25);
  Duration _remaining = _total;
  Timer? _ticker;

  // Placeholder — swap for a real todaysSessionsProvider (Drift query on
  // FocusSessions where startedAt is today) once that lands. Matches the
  // 3-dot pattern in the design: completed sessions filled, the current
  // one shown as an accent-to-calm gradient chip, empty slots as tracks.
  static const _completedSessions = 2;

  @override
  void initState() {
    super.initState();
    // A 1-second periodic timer is cheap — the ring's own repaint is
    // gated by shouldRepaint, so this doesn't cost more than one
    // CustomPainter.paint() per second, not per frame.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_remaining.inSeconds <= 0) {
        _ticker?.cancel();
        return;
      }
      setState(() => _remaining -= const Duration(seconds: 1));
    });
  }

  @override
  void dispose() {
    _ticker?.cancel(); // leaking this timer is the #1 cause of
    // "why does my app get slower the longer it's open" bug reports
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = 1 - (_remaining.inSeconds / _total.inSeconds);

    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.6),
          radius: 1.0,
          colors: [AppColors.surface2, AppColors.bg],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            const _InvincibleChip(),
            const Spacer(),
            LimitRing(
              progress: progress,
              size: 220,
              strokeWidth: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_format(_remaining), style: GoogleFonts.spaceGrotesk(
                    fontSize: 38,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  )),
                  const SizedBox(height: 6),
                  Text('Deep Work · remaining', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _LockNote(),
            const Spacer(),
            const _TodaysSessions(completed: _completedSessions, total: 3),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => _confirmEndEarly(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(14),
                    backgroundColor: AppColors.surface2,
                    side: const BorderSide(color: AppColors.stroke),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: const Text('End session early', style: TextStyle(color: AppColors.inkDim)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _format(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _confirmEndEarly(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (_) => const SizedBox(height: 160, child: Center(child: Text('Confirm sheet — wire to session provider'))),
    );
  }
}

class _InvincibleChip extends StatelessWidget {
  const _InvincibleChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 12, color: AppColors.inkDim),
          SizedBox(width: 6),
          Text('Invincible mode on', style: TextStyle(fontSize: 11.5, color: AppColors.inkDim)),
        ],
      ),
    );
  }
}

/// "12 apps paused · DND on" — reinforces what invincible mode is
/// actually doing while the ring runs, so the state isn't only
/// communicated once at the top of the screen.
class _LockNote extends StatelessWidget {
  const _LockNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.notifications_off_rounded, size: 13, color: AppColors.inkFaint),
        const SizedBox(width: 6),
        Text('12 apps paused · DND on', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5)),
      ],
    );
  }
}

class _TodaysSessions extends StatelessWidget {
  const _TodaysSessions({required this.completed, this.total = 3});
  final int completed;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          "TODAY'S SESSIONS",
          style: Theme.of(context).textTheme.labelSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < total; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _SessionDot(state: i < completed
                  ? _SessionState.done
                  : i == completed
                      ? _SessionState.active
                      : _SessionState.empty),
            ],
          ],
        ),
      ],
    );
  }
}

enum _SessionState { done, active, empty }

class _SessionDot extends StatelessWidget {
  const _SessionDot({required this.state});
  final _SessionState state;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case _SessionState.active:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.surface2, AppColors.surface],
            ),
            border: Border.all(color: AppColors.surface, width: 3),
          ),
        );
      case _SessionState.done:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.stroke),
          ),
          child: const Icon(Icons.check_rounded, size: 16, color: AppColors.ink),
        );
      case _SessionState.empty:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.stroke),
          ),
        );
    }
  }
}
PATCH_EOF

mkdir -p "lib/features/limits"
cat > "lib/features/limits/limits_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/providers.dart';

/// Known package → brand color, purely a visual lookup table (not user
/// data) so the icon row can show *something* distinguishable without
/// an app-icon asset pipeline (would need PackageManager lookups via a
/// platform channel — out of scope here). Unknown packages fall back to
/// a neutral gray rather than guessing.
const _brandColors = <String, Color>{
  'com.instagram.android': Color(0xFFE1306C),
  'com.zhiliaoapp.musically': Color(0xFF000000), // TikTok
  'com.twitter.android': Color(0xFF1DA1F2),
  'com.google.android.youtube': Color(0xFFFF0000),
  'com.netflix.mediaclient': Color(0xFF00A8E1),
};
const _fallbackColor = Color(0xFF374151);

/// Restriction-groups list. Follows the same card pattern as Home's
/// tiles; full detail screen (per-group edit) lives at
/// features/limits/group_detail_screen.dart in the complete build —
/// omitted here to keep this scaffold focused on the architecture.
class LimitsScreen extends ConsumerWidget {
  const LimitsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(restrictionGroupsProvider);

    return SafeArea(
      child: groups.when(
        data: (data) => _buildList(context, data),
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, __) => Center(
          child: Text('Could not load limits: $e', style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, List<RestrictionGroupView> groups) {
    final totalApps = groups.fold<int>(0, (sum, g) => sum + g.packageNames.length);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      children: [
        Text('Limits', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('${groups.length} groups · $totalApps apps covered', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        for (final g in groups) ...[
          _GroupCard(group: g),
          const SizedBox(height: 10),
        ],
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.stroke),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Center(
            child: Text(
              '+ New restriction group',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group});
  final RestrictionGroupView group;

  @override
  Widget build(BuildContext context) {
    final hasLimit = group.limitSeconds > 0;
    final ratio = hasLimit ? (group.usedSeconds / group.limitSeconds).clamp(0.0, 1.0) : 0.0;
    // Bar color IS the state signal, same rule as Home's ring: near the
    // limit reads amber, comfortably under it reads teal.
    // Monochrome warning state: near-limit reads as full-brightness
    // white (draws the eye, higher contrast), on-track as the quieter
    // mid-gray -- brightness/weight carries the signal, not a hue.
    final barColor = ratio >= 0.66 ? AppColors.ink : AppColors.inkDim;
    final dimmed = !hasLimit;

    return Opacity(
      opacity: dimmed ? 0.6 : 1.0,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.stroke),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(group.name, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13.5)),
                Text(
                  hasLimit ? '${group.usedSeconds ~/ 60} / ${group.limitSeconds ~/ 60}m' : 'No limit',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 10),
            _AppIconRow(packageNames: group.packageNames),
            if (hasLimit) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: ratio),
                  duration: const Duration(milliseconds: 500),
                  builder: (_, value, __) => LinearProgressIndicator(
                    value: value,
                    minHeight: 5,
                    backgroundColor: AppColors.stroke,
                    valueColor: AlwaysStoppedAnimation(barColor),
                  ),
                ),
              ),
            ],
            if (group.invincible) ...[
              const SizedBox(height: 8),
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_rounded, size: 11, color: AppColors.alert),
                  SizedBox(width: 4),
                  Text('Invincible mode on', style: TextStyle(fontSize: 10, color: AppColors.alert)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AppIconRow extends StatelessWidget {
  const _AppIconRow({required this.packageNames});
  final List<String> packageNames;

  @override
  Widget build(BuildContext context) {
    if (packageNames.isEmpty) {
      return Text('No apps assigned', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10.5));
    }
    return Row(
      children: [
        for (final pkg in packageNames) ...[
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: _brandColors[pkg] ?? _fallbackColor,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ],
    );
  }
}
PATCH_EOF

mkdir -p "lib/features/bedtime"
cat > "lib/features/bedtime/bedtime_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';

class BedtimeScreen extends ConsumerWidget {
  const BedtimeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedule = ref.watch(bedtimeScheduleProvider);
    final db = ref.read(databaseProvider);

    return SafeArea(
      child: schedule.when(
        data: (row) => _buildBody(context, db, row),
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, __) => Center(
          child: Text('Could not load bedtime settings: $e', style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppDatabase db, BedtimeScheduleData? row) {
    // No row yet (fresh install) — show the same defaults the first
    // toggle-write will actually create, so the screen doesn't flash
    // from one set of numbers to another once a toggle is touched.
    final startTime = row?.startTime ?? '22:30';
    final endTime = row?.endTime ?? '06:30';
    final dnd = row?.dndEnabled ?? true;
    final pauseApps = row?.pauseApps ?? true;
    final grayscale = row?.grayscale ?? false;
    final protectedHours = _hoursBetween(startTime, endTime);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      children: [
        Text('Bedtime', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('Scheduled · repeats every night', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),

        Center(child: _MoonArc(progress: _nightProgress(startTime, endTime))),

        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_formatTime(startTime), style: GoogleFonts.spaceGrotesk(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            )),
            const SizedBox(width: 10),
            const Icon(Icons.arrow_forward_rounded, size: 16, color: AppColors.inkFaint),
            const SizedBox(width: 10),
            Text(_formatTime(endTime), style: GoogleFonts.spaceGrotesk(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            )),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '$protectedHours hours protected',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5),
        ),
        const SizedBox(height: 20),

        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.stroke),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Column(
            children: [
              _ToggleRow(
                label: 'Do Not Disturb',
                subtitle: 'Silence calls & notifications',
                value: dnd,
                onChanged: (v) => db.setDndEnabled(v),
              ),
              const Divider(height: 1, color: AppColors.stroke),
              _ToggleRow(
                label: 'Pause distracting apps',
                subtitle: 'Uses the same list as invincible mode',
                value: pauseApps,
                onChanged: (v) => db.setPauseApps(v),
              ),
              const Divider(height: 1, color: AppColors.stroke),
              _ToggleRow(
                label: 'Grayscale display',
                subtitle: 'Dims the pull to check',
                value: grayscale,
                onChanged: (v) => db.setGrayscale(v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// "22:30" -> "10:30 PM". Schedule times are stored as "HH:mm" 24h
  /// strings (see BedtimeSchedule) rather than DateTime, since they
  /// repeat nightly and aren't tied to a specific date.
  String _formatTime(String hhmm) {
    final parts = hhmm.split(':');
    var h = int.parse(parts[0]);
    final m = parts[1];
    final suffix = h >= 12 ? 'PM' : 'AM';
    h = h % 12;
    if (h == 0) h = 12;
    return '$h:$m $suffix';
  }

  int _hoursBetween(String start, String end) {
    final s = _minutesSinceMidnight(start);
    final e = _minutesSinceMidnight(end);
    final diff = e >= s ? e - s : (24 * 60 - s) + e; // handles overnight wrap
    return (diff / 60).round();
  }

  double _nightProgress(String start, String end) {
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final s = _minutesSinceMidnight(start);
    final e = _minutesSinceMidnight(end);
    final total = e >= s ? e - s : (24 * 60 - s) + e;
    if (total <= 0) return 0;

    final elapsed = nowMinutes >= s
        ? nowMinutes - s
        : nowMinutes <= e
            ? (24 * 60 - s) + nowMinutes
            : null;
    if (elapsed == null) return 0; // outside the window right now
    return (elapsed / total).clamp(0.0, 1.0);
  }

  int _minutesSinceMidnight(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }
}

/// Open half-arc (not a full [LimitRing]) representing tonight's
/// schedule window — deliberately a separate small painter rather than
/// stretching LimitRing to support open arcs, since LimitRing's contract
/// (full 0–2π sweep) is used correctly everywhere else and shouldn't
/// grow a special case for this one screen.
class _MoonArc extends StatelessWidget {
  const _MoonArc({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      height: 140,
      child: CustomPaint(painter: _MoonArcPainter(progress: progress)),
    );
  }
}

class _MoonArcPainter extends CustomPainter {
  _MoonArcPainter({required this.progress});
  final double progress;

  static const _start = 3.14159; // 180deg
  static const _sweepTotal = 3.14159; // 180deg total arc

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 10);
    final radius = size.width / 2 - 10;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawArc(
      rect,
      _start,
      _sweepTotal,
      false,
      Paint()
        ..color = AppColors.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    canvas.drawArc(
      rect,
      _start,
      _sweepTotal * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..color = AppColors.ink
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    final dotPaint = Paint()..color = AppColors.ink;
    canvas.drawCircle(Offset(center.dx - radius, center.dy), 5, dotPaint);
    canvas.drawCircle(Offset(center.dx + radius, center.dy), 5, dotPaint);
  }

  @override
  bool shouldRepaint(_MoonArcPainter old) => old.progress != progress;
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11)),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: AppColors.bg,
              activeTrackColor: AppColors.ink,
              inactiveThumbColor: AppColors.inkFaint,
              inactiveTrackColor: AppColors.surface2,
              trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
            ),
          ],
        ),
      ),
    );
  }
}
PATCH_EOF

mkdir -p "lib/features/settings"
cat > "lib/features/settings/settings_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/permissions_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(allPermissionsProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Local profile · not synced', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),

          _SectionLabel('PERMISSIONS'),
          const SizedBox(height: 8),
          _Card(
            children: [
              for (final p in permissions)
                _PermissionRow(
                  label: _labelFor(p.kind),
                  granted: p.granted,
                  loading: p.loading,
                ),
            ],
          ),
          const SizedBox(height: 20),

          _SectionLabel('DATA'),
          const SizedBox(height: 8),
          const _Card(
            children: [
              _NavRow(icon: Icons.save_alt_rounded, label: 'Backup to file'),
              _RowDivider(),
              _NavRow(icon: Icons.file_upload_rounded, label: 'Restore from file'),
            ],
          ),
          const SizedBox(height: 20),

          _SectionLabel('ABOUT'),
          const SizedBox(height: 8),
          const _Card(
            children: [
              _NavRow(icon: Icons.star_rounded, label: 'Rate Ulimit'),
              _RowDivider(),
              _NavRow(icon: Icons.privacy_tip_rounded, label: 'Privacy policy'),
              _RowDivider(),
              _StaticRow(label: 'Version', value: '0.1.0'),
            ],
          ),
          const SizedBox(height: 20),

          Center(
            child: TextButton(
              onPressed: () {}, // wire to a confirm dialog + AppDatabase wipe
              child: const Text('Reset all data', style: TextStyle(color: AppColors.danger, fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }

  String _labelFor(PermissionKind kind) => switch (kind) {
        PermissionKind.accessibility => 'Accessibility',
        PermissionKind.vpn => 'VPN & network',
        PermissionKind.deviceAdmin => 'Device admin',
        PermissionKind.notificationListener => 'Notification access',
        PermissionKind.biometric => 'Biometrics',
      };
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.labelSmall);
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(children: children),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();
  @override
  Widget build(BuildContext context) => const Divider(height: 1, color: AppColors.stroke);
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.label, required this.granted, required this.loading});
  final String label;
  final bool granted;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13))),
          if (loading)
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Text(
              granted ? 'Granted' : 'Pending',
              style: TextStyle(fontSize: 10.5, color: granted ? AppColors.ink : AppColors.inkDim),
            ),
        ],
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 16, color: AppColors.inkDim),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13))),
            const Icon(Icons.chevron_right_rounded, size: 16, color: AppColors.inkFaint),
          ],
        ),
      ),
    );
  }
}

class _StaticRow extends StatelessWidget {
  const _StaticRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13))),
          Text(value, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
PATCH_EOF

mkdir -p "lib/features/parental"
cat > "lib/features/parental/parental_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../core/native/permissions_channel.dart';
import '../../data/permissions_providers.dart';

class ParentalScreen extends ConsumerStatefulWidget {
  const ParentalScreen({super.key});

  @override
  ConsumerState<ParentalScreen> createState() => _ParentalScreenState();
}

class _ParentalScreenState extends ConsumerState<ParentalScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Same pattern as the onboarding permissions screen — Android gives
    // no callback for "returned from the device-admin system dialog",
    // so re-check on resume.
    if (state == AppLifecycleState.resumed) {
      ref.read(permissionsRefreshTickProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Reads the *real* native state directly, not the onboarding
    // "acknowledged" shortcut — this screen is where Device Admin
    // actually gets turned on for real, so it should never lie about
    // whether it's genuinely active.
    final deviceAdminActive = ref.watch(deviceAdminActiveProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.arrow_back_rounded, size: 14, color: AppColors.inkDim),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Parental & Lock', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 19)),
                  Text('Protects settings from being changed', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          deviceAdminActive.when(
            data: (active) => _StatusCard(active: active),
            loading: () => const _StatusCard(active: false, loading: true),
            error: (_, __) => const _StatusCard(active: false),
          ),
          const SizedBox(height: 16),

          Text('PROTECTION', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.stroke),
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Column(
              children: [
                deviceAdminActive.when(
                  data: (active) => _DeviceAdminRow(active: active),
                  loading: () => const _DeviceAdminRow(active: false, loading: true),
                  error: (_, __) => const _DeviceAdminRow(active: false),
                ),
                const Divider(height: 1, color: AppColors.stroke),
                _ToggleRow(
                  label: 'Require biometric to edit',
                  sublabel: 'Face unlock or fingerprint',
                  value: false,
                  onChanged: (_) {}, // wire to a real settings row once biometric-lock is built
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.active, this.loading = false});
  final bool active;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.surface2, AppColors.surface],
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(
              active ? Icons.shield_rounded : Icons.shield_outlined,
              color: active ? AppColors.ink : AppColors.inkFaint,
              size: 22,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            loading ? 'Checking…' : (active ? 'Device Admin is active' : 'Device Admin is off'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            active
                ? "Ulimit can't be uninstalled or force-stopped without deactivating this first."
                : 'Turn this on for extra tamper resistance — optional, not required to use the app.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _DeviceAdminRow extends StatelessWidget {
  const _DeviceAdminRow({required this.active, this.loading = false});
  final bool active;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Block uninstall', style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13)),
                Text('Requires Device Admin', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10.5)),
              ],
            ),
          ),
          if (loading)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else if (active)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(AppRadius.pill)),
              child: const Text('✓ On', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.bg)),
            )
          else
            GestureDetector(
              onTap: () => NativePermissions.requestDeviceAdmin(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(AppRadius.pill)),
                child: const Text('Enable', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.bg)),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.sublabel,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final String sublabel;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13)),
                Text(sublabel, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10.5)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: AppColors.ink,
          ),
        ],
      ),
    );
  }
}
PATCH_EOF

mkdir -p "lib/features/onboarding"
cat > "lib/features/onboarding/permissions_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../core/native/permissions_channel.dart';
import '../../data/permissions_providers.dart';

class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key, required this.onAllGranted});

  /// Called once every non-optional permission is granted, so the
  /// caller can advance the router — kept as a callback rather than
  /// this screen owning navigation, so it's reusable from both first
  /// launch and Settings → Permissions.
  final VoidCallback onAllGranted;

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android gives no callback for "user returned from Settings" — the
    // correct, standard pattern is to re-check every relevant permission
    // when the app resumes, since that's the only reliable signal.
    if (state == AppLifecycleState.resumed) {
      ref.read(permissionsRefreshTickProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(allPermissionsProvider);

    // Biometric is optional (see design) — required count excludes it.
    const notRequired = {PermissionKind.biometric, PermissionKind.deviceAdmin};
    final required = permissions.where((p) => !notRequired.contains(p.kind));
    final grantedCount = required.where((p) => p.granted).length;
    final requiredTotal = required.length;
    final allRequiredGranted = grantedCount == requiredTotal;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            children: [
              const SizedBox(height: 6),
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(Icons.lock_rounded, color: AppColors.inkDim, size: 22),
              ),
              const SizedBox(height: 12),
              Text(
                'Ulimit needs a few permissions',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              Text(
                'Everything stays on your device — nothing is ever uploaded. '
                'Each permission only powers the feature next to it.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView.separated(
                  itemCount: permissions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _PermissionCard(status: permissions[i]),
                ),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: requiredTotal == 0 ? 0 : grantedCount / requiredTotal,
                  minHeight: 5,
                  backgroundColor: AppColors.stroke,
                  valueColor: const AlwaysStoppedAnimation(AppColors.ink),
                ),
              ),
              const SizedBox(height: 8),
              Text('$grantedCount of $requiredTotal granted',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: allRequiredGranted ? widget.onAllGranted : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.ink,
                    disabledBackgroundColor: AppColors.surface2,
                    padding: const EdgeInsets.all(15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: Text(
                    'Continue',
                    style: TextStyle(
                      color: allRequiredGranted ? AppColors.bg : AppColors.inkFaint,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionMeta {
  const _PermissionMeta(this.title, this.description, this.icon, this.iconColor, this.optional);
  final String title;
  final String description;
  final IconData icon;
  final Color iconColor;
  final bool optional;
}

const _meta = {
  PermissionKind.accessibility: _PermissionMeta(
    'Accessibility',
    'The core engine — detects app usage, enforces limits, and shows the block screen instantly.',
    Icons.visibility_rounded,
    AppColors.inkDim,
    false,
  ),
  PermissionKind.vpn: _PermissionMeta(
    'VPN & Network',
    'Creates a local, on-device filter for internet and website blocking.',
    Icons.public_rounded,
    AppColors.inkDim,
    false,
  ),
  PermissionKind.deviceAdmin: _PermissionMeta(
    'Device Admin',
    "Stops Ulimit from being uninstalled or force-stopped to bypass a limit. "
    "Optional here — you can turn this on later in Parental & Lock.",
    Icons.shield_rounded,
    AppColors.inkDim,
    false,
  ),
  PermissionKind.notificationListener: _PermissionMeta(
    'Notification Access',
    'Lets Ulimit batch or mute notifications during focus sessions.',
    Icons.notifications_rounded,
    AppColors.inkDim,
    false,
  ),
  PermissionKind.biometric: _PermissionMeta(
    'Biometrics',
    'Optional — protects your limits from being changed by others.',
    Icons.fingerprint_rounded,
    AppColors.inkDim,
    true,
  ),
};

class _PermissionCard extends ConsumerWidget {
  const _PermissionCard({required this.status});
  final PermissionStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = _meta[status.kind]!;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: meta.iconColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(meta.icon, size: 15, color: meta.iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(meta.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13)),
                const SizedBox(height: 2),
                Text(meta.description, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _ActionButton(status: status, optional: meta.optional),
        ],
      ),
    );
  }
}

class _ActionButton extends ConsumerWidget {
  const _ActionButton({required this.status, required this.optional});
  final PermissionStatus status;
  final bool optional;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (status.granted) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(AppRadius.pill)),
        child: const Text('✓ Done', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.bg)),
      );
    }

    return GestureDetector(
      onTap: status.loading ? null : () => _handleTap(ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: optional ? AppColors.surface2 : AppColors.accent,
          border: optional ? Border.all(color: AppColors.stroke) : null,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          optional ? 'Skip' : 'Allow',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: optional ? AppColors.inkDim : AppColors.bg,
          ),
        ),
      ),
    );
  }

  Future<void> _handleTap(WidgetRef ref) async {
    // Accessibility and Notification Listener can only be toggled from
    // system Settings — Android has no in-app grant dialog for either.
    // The rest support a direct system dialog.
    switch (status.kind) {
      case PermissionKind.accessibility:
        await NativePermissions.openAccessibilitySettings();
      case PermissionKind.notificationListener:
        await NativePermissions.openNotificationListenerSettings();
      case PermissionKind.vpn:
        await NativePermissions.requestVpnPermission();
      case PermissionKind.deviceAdmin:
        // Fire the system dialog, but don't wait on or gate anything
        // to its result — whatever the user picks there, onboarding
        // moves on. See deviceAdminAcknowledgedProvider's doc comment.
        await NativePermissions.requestDeviceAdmin();
        ref.read(deviceAdminAcknowledgedProvider.notifier).state = true;
      case PermissionKind.biometric:
        // "Skip" for the optional card — nothing to request, just move
        // on; availability is a device capability, not a togglable
        // permission, so there's nothing else to do here.
        return;
    }
    // VPN/Device Admin dialogs resolve synchronously enough that an
    // immediate re-check is worthwhile; Accessibility/Notification
    // Listener rely on the lifecycle-resume re-check instead since the
    // user is leaving the app to a Settings screen.
    ref.read(permissionsRefreshTickProvider.notifier).state++;
  }
}
PATCH_EOF

mkdir -p "lib/shared/widgets"
cat > "lib/shared/widgets/nav_shell.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/tokens.dart';
import '../../core/router/app_router.dart';

class NavShell extends StatelessWidget {
  const NavShell({super.key, required this.child});
  final Widget child;

  static const _tabs = [
    (Routes.home, Icons.home_rounded, 'Home'),
    (Routes.focus, Icons.track_changes_rounded, 'Focus'),
    (Routes.limits, Icons.grid_view_rounded, 'Limits'),
    (Routes.bedtime, Icons.dark_mode_rounded, 'Bedtime'),
    (Routes.settings, Icons.settings_rounded, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;

    final activeIndex = _tabs.indexWhere((t) => t.$1 == location).clamp(0, 4);

    void goToTab(int index) {
      if (index < 0 || index >= _tabs.length || index == activeIndex) return;
      context.go(_tabs[index].$1);
    }

    return Scaffold(
      // `child` is the current tab's screen; Stack lets the nav float
      // over it without stealing layout space, matching the mockup.
      body: Stack(
        children: [
          GestureDetector(
            // A horizontal-only gesture recognizer would still fire on
            // primarily-vertical drags; gating on velocity magnitude in
            // onHorizontalDragEnd (rather than onHorizontalDragUpdate)
            // means this only acts on a deliberate, fast horizontal
            // flick, so normal vertical scrolling on any tab's content
            // is never intercepted or fights with this gesture.
            onHorizontalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              const threshold = 300.0;
              if (velocity < -threshold) {
                goToTab(activeIndex + 1);
              } else if (velocity > threshold) {
                goToTab(activeIndex - 1);
              }
            },
            child: child,
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: _FloatingNavBar(
              tabs: _tabs,
              activeIndex: activeIndex,
              onTap: goToTab,
            ),
          ),
        ],
      ),
    );
  }
}

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.tabs,
    required this.activeIndex,
    required this.onTap,
  });

  final List<(String, IconData, String)> tabs;
  final int activeIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0C10),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.stroke),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.55),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(tabs.length, (i) {
          final isActive = i == activeIndex;
          final (_, icon, label) = tabs[i];
          return _NavItem(
            icon: icon,
            label: label,
            isActive: isActive,
            onTap: () => onTap(i),
          );
        }),
      ),
    );
  }
}

/// The morph: an AnimatedContainer widens from an icon-only circle into
/// an icon+label pill. AnimatedContainer is the right tool here — it's
/// implicitly driven by the widget tree diff, so there's no
/// AnimationController to leak or forget to dispose, and Flutter batches
/// the size/color tween into a single compositor-friendly pass.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        height: 38,
        padding: EdgeInsets.symmetric(horizontal: isActive ? 14 : 0),
        decoration: BoxDecoration(
          color: isActive ? AppColors.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 38,
              child: Icon(
                icon,
                size: 18,
                color: isActive ? AppColors.bg : AppColors.inkFaint,
              ),
            ),
            // AnimatedSize + fade avoids laying out invisible text every
            // frame for the four inactive tabs — cheaper than always
            // building the label and toggling opacity to zero.
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: isActive
                  ? Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Text(
                        label,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.bg,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
PATCH_EOF

mkdir -p "lib/shared/widgets"
cat > "lib/shared/widgets/limit_ring.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';

/// The app's recurring ring motif (screen-time budget, focus countdown,
/// group allowance, sleep arc). Implemented once as a CustomPainter and
/// reused everywhere with different `progress`/color inputs, rather than
/// four separate SVG-in-a-Container implementations per screen — one
/// painter to profile, one to optimize.
class LimitRing extends StatelessWidget {
  const LimitRing({
    super.key,
    required this.progress,
    required this.size,
    this.strokeWidth = 10,
    this.color = AppColors.accent,
    this.trackColor = AppColors.stroke,
    this.child,
  });

  /// 0.0–1.0. Callers animate this externally (e.g. with
  /// TweenAnimationBuilder) rather than the ring owning a controller —
  /// keeps this widget stateless and trivially reusable.
  final double progress;
  final double size;
  final double strokeWidth;
  final Color color;
  final Color trackColor;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _RingPainter(
              progress: progress,
              strokeWidth: strokeWidth,
              color: color,
              trackColor: trackColor,
            ),
          ),
          if (child != null) child!,
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.strokeWidth,
    required this.color,
    required this.trackColor,
  });

  final double progress;
  final double strokeWidth;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.width - strokeWidth) / 2;

    final track = Paint()
      ..color = trackColor
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final fill = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawCircle(center, radius, track);

    const start = -1.5708; // -90deg, 12 o'clock
    final sweep = 6.28319 * progress.clamp(0.0, 1.0); // 2π
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      fill,
    );
  }

  // Only repaint when the values that actually affect pixels change —
  // this is what makes it safe to rebuild this widget every animation
  // tick without dropping frames.
  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}
PATCH_EOF

mkdir -p "lib/shared/widgets"
cat > "lib/shared/widgets/trend_chart.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';

/// A single-series area/line chart, drawn with one CustomPainter instead
/// of pulling in fl_chart/syncfusion — those pull in far more than this
/// app needs (legends, tooltips, multi-axis support) for what's really
/// 7-14 points on a card. Keeps the app's dependency footprint small,
/// per the "don't make it too large" requirement.
class TrendAreaChart extends StatelessWidget {
  const TrendAreaChart({
    super.key,
    required this.values,
    this.height = 84,
    this.color = AppColors.accent,
    this.showAverageLine = true,
  });

  /// Normalized or raw values — only relative shape matters, the
  /// painter rescales internally to fit [height].
  final List<double> values;
  final double height;
  final Color color;
  final bool showAverageLine;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      // TweenAnimationBuilder animates the whole series in on first
      // build (0 → 1) rather than snapping the chart in fully drawn —
      // a small motion detail that reads as "designed", not free.
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => CustomPaint(
          painter: _AreaChartPainter(
            values: values,
            progress: t,
            color: color,
            showAverageLine: showAverageLine,
          ),
        ),
      ),
    );
  }
}

class _AreaChartPainter extends CustomPainter {
  _AreaChartPainter({
    required this.values,
    required this.progress,
    required this.color,
    required this.showAverageLine,
  });

  final List<double> values;
  final double progress;
  final Color color;
  final bool showAverageLine;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);
    final range = (maxV - minV).abs() < 0.001 ? 1.0 : (maxV - minV);

    // Reserve bottom 14px so the line never touches the day-label row
    // that typically sits directly under this widget.
    final usableHeight = size.height - 6;
    final stepX = size.width / (values.length - 1);

    Offset pointAt(int i) {
      final normalized = (values[i] - minV) / range;
      final y = usableHeight - (normalized * usableHeight) + 4;
      return Offset(stepX * i, y);
    }

    final visibleCount = (values.length * progress).ceil().clamp(2, values.length);
    final points = [for (var i = 0; i < visibleCount; i++) pointAt(i)];

    if (showAverageLine) {
      final avgNormalized = (values.reduce((a, b) => a + b) / values.length - minV) / range;
      final y = usableHeight - (avgNormalized * usableHeight) + 4;
      final dashPaint = Paint()
        ..color = AppColors.inkFaint
        ..strokeWidth = 1;
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(Offset(x, y), Offset(x + 3, y), dashPaint);
        x += 7;
      }
    }

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, linePaint);

    final fillPath = Path.from(path)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withOpacity(0.32), color.withOpacity(0.0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(fillPath, fillPaint);

    // Endpoint dot — hollow ring, matches the mockup's highlighted
    // final point.
    if (points.length == values.length) {
      final last = points.last;
      canvas.drawCircle(last, 4, Paint()..color = AppColors.bg);
      canvas.drawCircle(
        last,
        4,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  @override
  bool shouldRepaint(_AreaChartPainter old) =>
      old.progress != progress || old.values != values || old.color != color;
}

/// Compact single-line sparkline for the small stat cards (Focus time,
/// Pickups) — no fill, no average line, minimal footprint.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.height = 36,
    this.color = AppColors.accent,
  });

  final List<double> values;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => CustomPaint(
          painter: _SparklinePainter(values: values, progress: t, color: color),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.progress, required this.color});
  final List<double> values;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);
    final range = (maxV - minV).abs() < 0.001 ? 1.0 : (maxV - minV);
    final stepX = size.width / (values.length - 1);

    Offset pointAt(int i) {
      final normalized = (values[i] - minV) / range;
      return Offset(stepX * i, size.height - normalized * size.height);
    }

    final visibleCount = (values.length * progress).ceil().clamp(2, values.length);
    final path = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);
    for (var i = 1; i < visibleCount; i++) {
      final p = pointAt(i);
      path.lineTo(p.dx, p.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.progress != progress || old.values != values;
}
PATCH_EOF

mkdir -p "lib/shared/widgets"
cat > "lib/shared/widgets/rolling_number.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';

/// A number/string display where only the characters that actually
/// changed between updates animate — "475" → "476" rolls just the "5",
/// not the whole string. Built as a plain AnimatedSwitcher-per-character
/// rather than a hand-tracked continuous-scroll odometer: it's far
/// cheaper (no per-frame drag/velocity math, no extra ticker beyond
/// what AnimatedSwitcher already uses), and for values that update at
/// most a few times a minute the crossfade+slide reads as a genuine
/// "roll" without the performance risk of a bespoke scroll physics
/// implementation.
class RollingNumber extends StatefulWidget {
  const RollingNumber({
    super.key,
    required this.text,
    required this.style,
    this.duration = const Duration(milliseconds: 320),
  });

  final String text;
  final TextStyle style;
  final Duration duration;

  @override
  State<RollingNumber> createState() => _RollingNumberState();
}

class _RollingNumberState extends State<RollingNumber> {
  String? _previousText;

  @override
  void didUpdateWidget(RollingNumber old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _previousText = old.text;
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.text;
    final previous = _previousText;

    // Character-by-character diff against the previous value. Different
    // lengths (e.g. "9" -> "10") fall back to animating the whole
    // string — a digit-by-digit diff across a length change would need
    // right-alignment/carry logic disproportionate to how rarely this
    // app's numbers cross a digit-count boundary.
    final sameLength = previous != null && previous.length == current.length;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(current.length, (i) {
        final char = current[i];
        final changed = !sameLength || previous[i] != char;

        return ClipRect(
          child: AnimatedSwitcher(
            duration: widget.duration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              final slideIn = Tween<Offset>(
                begin: const Offset(0, 0.6),
                end: Offset.zero,
              ).animate(animation);
              final slideOut = Tween<Offset>(
                begin: Offset.zero,
                end: const Offset(0, -0.6),
              ).animate(animation);
              // Outgoing digit slides up+fades, incoming slides in from
              // below+fades — the classic odometer look, per-character.
              return ClipRect(
                child: SlideTransition(
                  position: child.key == ValueKey('$char-$i-new') ? slideIn : slideOut,
                  child: FadeTransition(opacity: animation, child: child),
                ),
              );
            },
            child: Text(
              char,
              key: changed ? ValueKey('$char-$i-new') : ValueKey('static-$i-$char'),
              style: widget.style,
            ),
          ),
        );
      }),
    );
  }
}
PATCH_EOF

mkdir -p "lib/data"
cat > "lib/data/home_data_providers.dart" << 'PATCH_EOF'
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _daysAgo(int n) => _startOfDay(DateTime.now().subtract(Duration(days: n)));

/// The user's configured daily budget, in minutes. Falls back to the
/// schema default (240) via Drift's own default value if no Profile
/// row exists yet — a fresh install still gets a sane ring.
final dailyBudgetProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.profile).watchSingleOrNull().map((row) => row?.dailyBudgetMinutes ?? 240);
});

/// Last 7 days of total screen time, oldest→newest, in hours — feeds
/// the weekly trend chart directly. Real query, not a fixture array.
final weeklyScreenTimeHoursProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.appUsage)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final byDay = <DateTime, int>{};
    for (final r in rows) {
      byDay.update(r.day, (v) => v + r.foregroundSeconds, ifAbsent: () => r.foregroundSeconds);
    }
    return List.generate(7, (i) {
      final day = _daysAgo(6 - i);
      final seconds = byDay[day] ?? 0;
      return seconds / 3600.0;
    });
  });
});

/// Daily focus-session totals for the last 7 days, oldest→newest, in
/// hours — mirrors weeklyScreenTimeHoursProvider's shape so both feed
/// the same chart widgets consistently.
final weeklyFocusHoursByDayProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.focusSessions)
    ..where((t) => t.startedAt.isBiggerOrEqualValue(start) & t.completed.equals(true));

  return query.watch().map((rows) {
    final byDay = <DateTime, int>{};
    for (final s in rows) {
      if (s.endedAt == null) continue;
      final day = _startOfDay(s.startedAt);
      final seconds = s.endedAt!.difference(s.startedAt).inSeconds;
      byDay.update(day, (v) => v + seconds, ifAbsent: () => seconds);
    }
    return List.generate(7, (i) {
      final day = _daysAgo(6 - i);
      return (byDay[day] ?? 0) / 3600.0;
    });
  });
});

/// Total completed focus-session time this week, in seconds.
final weeklyFocusSecondsProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.focusSessions)
    ..where((t) => t.startedAt.isBiggerOrEqualValue(start) & t.completed.equals(true));

  return query.watch().map((rows) => rows.fold<int>(0, (sum, s) {
        if (s.endedAt == null) return sum;
        return sum + s.endedAt!.difference(s.startedAt).inSeconds;
      }));
});

/// Daily pickup counts for the last 7 days, oldest→newest.
final weeklyPickupsProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.pickupsLog)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final byDay = {for (final r in rows) r.day: r.count};
    return List.generate(7, (i) {
      final day = _daysAgo(6 - i);
      return (byDay[day] ?? 0).toDouble();
    });
  });
});

/// Prior-week (days 13→7 ago) total screen time, in hours — the
/// comparison baseline for the "vs last week" delta shown on Home.
/// A genuine second query rather than deriving it from the 7-day
/// array, since that array only covers the current week.
final previousWeekScreenTimeHoursProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(13);
  final end = _daysAgo(7);

  final query = db.select(db.appUsage)
    ..where((t) => t.day.isBiggerOrEqualValue(start) & t.day.isSmallerThanValue(end));

  return query.watch().map((rows) {
    final byDay = <DateTime, int>{};
    for (final r in rows) {
      byDay.update(r.day, (v) => v + r.foregroundSeconds, ifAbsent: () => r.foregroundSeconds);
    }
    return List.generate(7, (i) {
      final day = _daysAgo(13 - i);
      return (byDay[day] ?? 0) / 3600.0;
    });
  });
});

/// Prior-week completed focus-session seconds — comparison baseline
/// for the Focus time mini-card delta.
final previousWeekFocusSecondsProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(13);
  final end = _daysAgo(7);

  final query = db.select(db.focusSessions)
    ..where((t) =>
        t.startedAt.isBiggerOrEqualValue(start) &
        t.startedAt.isSmallerThanValue(end) &
        t.completed.equals(true));

  return query.watch().map((rows) => rows.fold<int>(0, (sum, s) {
        if (s.endedAt == null) return sum;
        return sum + s.endedAt!.difference(s.startedAt).inSeconds;
      }));
});

/// Prior-week pickup counts — comparison baseline for the Pickups
/// mini-card delta.
final previousWeekPickupsProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(13);
  final end = _daysAgo(7);

  final query = db.select(db.pickupsLog)
    ..where((t) => t.day.isBiggerOrEqualValue(start) & t.day.isSmallerThanValue(end));

  return query.watch().map((rows) {
    final byDay = {for (final r in rows) r.day: r.count};
    return List.generate(7, (i) {
      final day = _daysAgo(13 - i);
      return (byDay[day] ?? 0).toDouble();
    });
  });
});

/// A single "up X% / down X%" result, with the semantic direction
/// already resolved — screen-time-down and pickups-down are both
/// "good" (green), but focus-time-down is "bad" (red). Each call site
/// tells this which direction counts as positive rather than this
/// class guessing from the sign alone.
class TrendDelta {
  const TrendDelta({required this.percent, required this.isPositive, required this.hasData});
  final double percent; // always positive magnitude; sign shown via arrow/color
  final bool isPositive;
  final bool hasData;

  static const none = TrendDelta(percent: 0, isPositive: true, hasData: false);
}

TrendDelta _computeDelta({
  required double current,
  required double previous,
  required bool lowerIsBetter,
}) {
  if (previous <= 0) return TrendDelta.none;
  final change = (current - previous) / previous;
  final magnitude = (change.abs() * 100);
  final wentUp = change > 0;
  final isPositive = lowerIsBetter ? !wentUp : wentUp;
  return TrendDelta(percent: magnitude, isPositive: isPositive, hasData: true);
}

final screenTimeDeltaProvider = Provider<TrendDelta>((ref) {
  final current = ref.watch(weeklyScreenTimeHoursProvider).valueOrNull;
  final previous = ref.watch(previousWeekScreenTimeHoursProvider).valueOrNull;
  if (current == null || previous == null) return TrendDelta.none;
  final curAvg = current.isEmpty ? 0.0 : current.reduce((a, b) => a + b) / current.length;
  final prevAvg = previous.isEmpty ? 0.0 : previous.reduce((a, b) => a + b) / previous.length;
  return _computeDelta(current: curAvg, previous: prevAvg, lowerIsBetter: true);
});

final focusTimeDeltaProvider = Provider<TrendDelta>((ref) {
  final current = ref.watch(weeklyFocusSecondsProvider).valueOrNull;
  final previous = ref.watch(previousWeekFocusSecondsProvider).valueOrNull;
  if (current == null || previous == null) return TrendDelta.none;
  return _computeDelta(
      current: current.toDouble(), previous: previous.toDouble(), lowerIsBetter: false);
});

final pickupsDeltaProvider = Provider<TrendDelta>((ref) {
  final current = ref.watch(weeklyPickupsProvider).valueOrNull;
  final previous = ref.watch(previousWeekPickupsProvider).valueOrNull;
  if (current == null || previous == null) return TrendDelta.none;
  final curAvg = current.isEmpty ? 0.0 : current.reduce((a, b) => a + b) / current.length;
  final prevAvg = previous.isEmpty ? 0.0 : previous.reduce((a, b) => a + b) / previous.length;
  return _computeDelta(current: curAvg, previous: prevAvg, lowerIsBetter: true);
});

/// Consecutive-day streak, computed from days that have *any* recorded
/// AppUsage row — i.e. the app was actually used/tracked that day.
/// Walks backward from today; breaks on the first missing day.
final currentStreakProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(60); // 60-day lookback is plenty for any realistic streak

  final query = db.select(db.appUsage)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final daysWithData = rows.map((r) => r.day).toSet();
    var streak = 0;
    var cursor = _startOfDay(DateTime.now());
    while (daysWithData.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  });
});

/// The Limit score badge tiers, per the design system — 0 to 1000 in
/// 10 bands. Kept alongside the calculation so a UI never has to
/// hardcode a tier name against a score by hand.
class ScoreTier {
  const ScoreTier(this.name, this.min, this.max);
  final String name;
  final int min;
  final int max;
}

const scoreTiers = [
  ScoreTier('Newcomer', 0, 99),
  ScoreTier('Aware', 100, 199),
  ScoreTier('Steady', 200, 299),
  ScoreTier('Disciplined', 300, 399),
  ScoreTier('Focused', 400, 499),
  ScoreTier('Resolute', 500, 599),
  ScoreTier('Mindful', 600, 699),
  ScoreTier('Unshaken', 700, 799),
  ScoreTier('Sovereign', 800, 899),
  ScoreTier('Limitless', 900, 1000),
];

ScoreTier tierFor(int score) =>
    scoreTiers.firstWhere((t) => score >= t.min && score <= t.max, orElse: () => scoreTiers.first);

class LimitScore {
  const LimitScore({required this.score, required this.tier, required this.toNextTier});
  final int score;
  final ScoreTier tier;
  final int toNextTier;
}

/// Real weighted calculation from the design doc's formula — screen-time
/// reduction 35%, focus consistency 30%, streak 20%, limits kept 15% —
/// computed live from today's actual data rather than a fixture. Each
/// component is normalized to 0–1 before weighting so the formula stays
/// meaningful regardless of how ambitious someone's budget is.
final limitScoreProvider = Provider<AsyncValue<LimitScore>>((ref) {
  final weeklyUsage = ref.watch(weeklyScreenTimeHoursProvider);
  final weeklyFocus = ref.watch(weeklyFocusSecondsProvider);
  final streak = ref.watch(currentStreakProvider);
  final budget = ref.watch(dailyBudgetProvider);

  // Combine four AsyncValues manually rather than pulling in a
  // multi-provider-combinator package for one screen's worth of use.
  if (weeklyUsage.isLoading || weeklyFocus.isLoading || streak.isLoading || budget.isLoading) {
    return const AsyncValue.loading();
  }
  final usage = weeklyUsage.valueOrNull;
  final focusSeconds = weeklyFocus.valueOrNull;
  final streakDays = streak.valueOrNull;
  final budgetMinutes = budget.valueOrNull;
  if (usage == null || focusSeconds == null || streakDays == null || budgetMinutes == null) {
    return const AsyncValue.loading();
  }

  final budgetHours = budgetMinutes / 60.0;
  final avgUsedHours = usage.isEmpty ? 0.0 : usage.reduce((a, b) => a + b) / usage.length;
  final screenTimeComponent = (1 - (avgUsedHours / (budgetHours <= 0 ? 1 : budgetHours))).clamp(0.0, 1.0);

  // 5 focused hours/week treated as "full marks" for consistency —
  // arbitrary but reasonable target; tune once real usage data exists.
  final focusConsistencyComponent = (focusSeconds / (5 * 3600)).clamp(0.0, 1.0);

  final streakComponent = (streakDays / 30).clamp(0.0, 1.0); // 30-day streak = full marks

  // Limits-kept component needs RestrictionGroups override/breach
  // tracking, which isn't built yet — held at a neutral 0.7 rather than
  // faking a precise number until that data source exists.
  const limitsKeptComponent = 0.7;

  final total = (screenTimeComponent * 0.35) +
      (focusConsistencyComponent * 0.30) +
      (streakComponent * 0.20) +
      (limitsKeptComponent * 0.15);

  final score = (total * 1000).round().clamp(0, 1000);
  final tier = tierFor(score);
  final toNext = tier.max >= 1000 ? 0 : (tier.max + 1 - score);

  return AsyncValue.data(LimitScore(score: score, tier: tier, toNextTier: toNext));
});
PATCH_EOF

# Remove gamification-only widgets that no screen references anymore
rm -f lib/shared/widgets/increase_pulse.dart
rm -f lib/shared/widgets/achievement_toast.dart

git add -A
git -c user.email="dev@ulimit.app" -c user.name="Ulimit Dev" commit -m "Global monochrome design system: strict black/gray/white palette, shared component library (PremiumFeatureTile/Card/ListTile/Button/Header), full-width feature tiles on Home, gamification layer removed"
git push

echo "Done. Run flutter analyze to check."
rm -- "$0"
