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
          const _GroupCard(name: 'Social Scroll', usedMinutes: 42, limitMinutes: 60, locked: true),
          const SizedBox(height: 10),
          const _GroupCard(name: 'Video', usedMinutes: 12, limitMinutes: 90, locked: false),
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
  });

  final String name;
  final int usedMinutes;
  final int limitMinutes;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final ratio = (usedMinutes / limitMinutes).clamp(0.0, 1.0);
    return Container(
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
              Text('$usedMinutes / ${limitMinutes}m', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
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
                valueColor: const AlwaysStoppedAnimation(AppColors.accent),
              ),
            ),
          ),
          if (locked) ...[
            const SizedBox(height: 8),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.lock_rounded, size: 11, color: AppColors.accent),
                SizedBox(width: 4),
                Text('Locked until reset', style: TextStyle(fontSize: 10, color: AppColors.accent)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
