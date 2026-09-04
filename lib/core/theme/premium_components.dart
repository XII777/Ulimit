import 'package:flutter/material.dart';
import '../../shared/widgets/pressable_scale.dart';
import '../icons/app_icons.dart';
import 'tokens.dart';

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

  /// Pre-rendered icon widget (typically an [AppIcon]) so the tile
  /// stays icon-system agnostic.
  final Widget icon;
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
            child: IconTheme.merge(
              data: const IconThemeData(size: 18),
              child: icon,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: AppText.title, fontWeight: FontWeight.w600, color: AppColors.ink)),
                const SizedBox(height: 2),
                Text(
                  description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: AppText.caption, color: AppColors.inkDim),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing ??
              Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.inkFaint),
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
        style: TextStyle(
          fontSize: AppText.overline,
          color: AppColors.inkFaint,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w600,
        ),
      );
}

/// A tappable section header that collapses/expands its child card.
/// Used by Settings for the GENERAL / FOCUS / PERMISSIONS / DATA /
/// ABOUT categories. The header is a CONTROL-TILE-style row — 38dp
/// icon holder + 16pt semibold title (the exact language of the home
/// Controls tiles) — with the rotating chevron as the only trailing
/// element. The card below animates its height (AnimatedSize) instead
/// of popping in/out, and taps anywhere on the header toggle.
class CollapsibleSection extends StatelessWidget {
  const CollapsibleSection({
    super.key,
    required this.label,
    required this.expanded,
    required this.onToggle,
    required this.child,
    this.icon,
  });

  final String label;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  /// Section icon, rendered in the tile-style holder (same box, radius
  /// and ink palette as the home Controls tiles).
  final AppIconName? icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Whole-row hit target — not just the chevron: a fat tap zone
        // is easier on a phone and matches how every other tile works.
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(AppRadius.md),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                if (icon != null) ...[
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(color: AppColors.stroke),
                    ),
                    child: AppIcon(
                      icon!,
                      size: 18,
                      color: expanded ? AppColors.ink : AppColors.inkDim,
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                        fontSize: AppText.title,
                        fontWeight: FontWeight.w600,
                        color: AppColors.ink),
                  ),
                ),
                // Chevron rotates 180° when open. CurvedRotationTransition
                // animates the turn itself — same motion language as the
                // nav pill and sheet handle, ~200ms easeOutCubic.
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  child: AppIcon(
                    AppIconName.chevronRight,
                    size: 14,
                    color: AppColors.inkFaint,
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          height: 8,
        ),
        // AnimatedSize smooths the height change; the enclosing Column
        // is a ListView child so the whole list reflows continuously.
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded ? child : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
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
            icon: AppIcon(AppIconName.back, size: 15, color: AppColors.inkDim),
            onPressed: onBack ?? () => Navigator.of(context).maybePop(),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: AppText.headline, fontWeight: FontWeight.w600, color: AppColors.ink)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: TextStyle(fontSize: AppText.caption, color: AppColors.inkDim)),
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
    this.labelColor,
  });

  final String label;
  final String? sublabel;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Overrides the default ink label color — used for destructive rows
  /// (danger) or state-colored labels.
  final Color? labelColor;

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
                Text(label,
                    style: TextStyle(
                        fontSize: AppText.body,
                        color: labelColor ?? AppColors.ink)),
                if (sublabel != null) ...[
                  const SizedBox(height: 2),
                  Text(sublabel!, style: TextStyle(fontSize: AppText.caption, color: AppColors.inkDim)),
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
  Widget build(BuildContext context) => Divider(height: 1, color: AppColors.stroke);
}
