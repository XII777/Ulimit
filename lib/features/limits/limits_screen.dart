import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';

/// Restriction-groups list. Follows the same card pattern as Home's
/// tiles; full detail screen (per-group edit) lives at
/// features/limits/group_detail_screen.dart in the complete build —
/// omitted here to keep this scaffold focused on the architecture.
class LimitsScreen extends StatelessWidget {
  const LimitsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
        children: [
          Text('Limits', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('3 groups · 7 apps covered', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          const _GroupCard(
            name: 'Social Scroll',
            usedMinutes: 42,
            limitMinutes: 60,
            locked: true,
            appColors: [Color(0xFFE1306C), Color(0xFF000000), Color(0xFF1DA1F2)],
          ),
          const SizedBox(height: 10),
          const _GroupCard(
            name: 'Video',
            usedMinutes: 12,
            limitMinutes: 90,
            locked: false,
            appColors: [Color(0xFFFF0000), Color(0xFF00A8E1)],
          ),
          const SizedBox(height: 10),
          const _GroupCard(
            name: 'Games',
            usedMinutes: null,
            limitMinutes: null,
            locked: false,
            appColors: [Color(0xFF374151), Color(0xFF374151)],
            dimmed: true,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.stroke, style: BorderStyle.solid),
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
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.name,
    required this.usedMinutes,
    required this.limitMinutes,
    required this.locked,
    required this.appColors,
    this.dimmed = false,
  });

  final String name;
  final int? usedMinutes;
  final int? limitMinutes;
  final bool locked;
  final List<Color> appColors;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final hasLimit = usedMinutes != null && limitMinutes != null;
    final ratio = hasLimit ? (usedMinutes! / limitMinutes!).clamp(0.0, 1.0) : 0.0;
    // Bar color IS the state signal, same rule as Home's ring: near the
    // limit reads amber, comfortably under it reads teal.
    final barColor = ratio >= 0.66 ? AppColors.alert : AppColors.calm;

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
                Text(name, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13.5)),
                Text(
                  hasLimit ? '$usedMinutes / ${limitMinutes}m' : 'No limit',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 10),
            _AppIconRow(colors: appColors),
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
            if (locked) ...[
              const SizedBox(height: 8),
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_rounded, size: 11, color: AppColors.alert),
                  SizedBox(width: 4),
                  Text('Invincible until 6:00 AM', style: TextStyle(fontSize: 10, color: AppColors.alert)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small colored squares standing in for real per-app icons — this repo
/// has no app-icon asset pipeline yet (would need PackageManager lookups
/// via the platform channel), so brand-color swatches communicate "which
/// apps" without faking icons that aren't actually loaded.
class _AppIconRow extends StatelessWidget {
  const _AppIconRow({required this.colors});
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final c in colors) ...[
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(6)),
          ),
          const SizedBox(width: 6),
        ],
      ],
    );
  }
}
