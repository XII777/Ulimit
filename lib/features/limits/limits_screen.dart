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
    final barColor = ratio >= 0.66 ? AppColors.alert : AppColors.calm;
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
