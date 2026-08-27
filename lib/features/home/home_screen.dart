import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/providers.dart';
import '../../shared/widgets/limit_ring.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only this value rebuilds on DB change — the header, tiles grid,
    // and everything else below stay untouched. This is the whole
    // point of scoping providers narrowly instead of one big
    // "HomeState" object.
    final screenTime = ref.watch(todayScreenTimeProvider);

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topCenter,
          radius: 1.1,
          colors: [Color(0x3A8B7FE8), Colors.transparent],
          stops: [0.0, 0.6],
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
          children: [
            Text('Today', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 2),
            Text(_formattedDate(), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),

            const _LimitScoreBanner(score: 475, tier: 'Focused'),
            const SizedBox(height: 16),

            Center(
              child: screenTime.when(
                data: (used) => _ScreenTimeRing(used: used, budget: const Duration(hours: 4)),
                // Skeleton state instead of a spinner — a spinner would
                // be the only moving thing on a static-looking screen
                // and reads as slower than it is.
                loading: () => LimitRing(
                  progress: 0,
                  size: 118,
                  trackColor: AppColors.stroke,
                ),
                error: (_, __) => const Icon(Icons.error_outline, color: AppColors.danger),
              ),
            ),
            const SizedBox(height: 20),

            Text('CONTROLS', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            const _ControlsGrid(),
          ],
        ),
      ),
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
    final progress = 1 - (used.inSeconds / budget.inSeconds).clamp(0.0, 1.0);

    // TweenAnimationBuilder animates the ring smoothly whenever `progress`
    // changes (e.g. a minute ticks over) instead of snapping — cheap
    // because it only rebuilds the ring subtree, not the screen.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: progress),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => LimitRing(
        progress: value,
        size: 118,
        strokeWidth: 8,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _formatDuration(remaining),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text('LEFT TODAY', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _LimitScoreBanner extends StatelessWidget {
  const _LimitScoreBanner({required this.score, required this.tier});
  final int score;
  final String tier;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [AppColors.accent, AppColors.accentSoft, AppColors.accent],
                ),
              ),
              child: Center(
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(color: AppColors.surface, shape: BoxShape.circle),
                  child: const Icon(Icons.shield_rounded, size: 18, color: AppColors.ink),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('$score', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 6),
                      Text('Limit', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  Text('$tier tier', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.accent, size: 18),
          ],
        ),
      ),
    );
  }
}

class _ControlsGrid extends StatelessWidget {
  const _ControlsGrid();

  static const _tiles = [
    ('Focus', Icons.track_changes_rounded, '3 sessions · 1h 40m today'),
    ('App Limits', Icons.grid_view_rounded, '3 groups · 1 near limit'),
    ('App Blocking', Icons.block_rounded, '5 apps blocked'),
    ('Internet & Sites', Icons.public_rounded, 'VPN active'),
    ('Notifications', Icons.notifications_rounded, 'Batching every 30 min'),
    ('Bedtime', Icons.dark_mode_rounded, '10:30 PM – 6:30 AM'),
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _tiles.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 9,
        crossAxisSpacing: 9,
        childAspectRatio: 1.5,
      ),
      itemBuilder: (context, i) {
        final (title, icon, subtitle) = _tiles[i];
        return _ControlTile(title: title, icon: icon, subtitle: subtitle);
      },
    );
  }
}

class _ControlTile extends StatelessWidget {
  const _ControlTile({required this.title, required this.icon, required this.subtitle});
  final String title;
  final IconData icon;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () {}, // wire to detail routes
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.stroke),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 15, color: AppColors.accentSoft),
              ),
              Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 12.5)),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
