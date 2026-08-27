#!/usr/bin/env bash
# Fixes flutter analyze: prefer_const_constructors warnings in the
# weekly trend card header (home_screen.dart).
# Applies the fix, commits, pushes, then deletes itself.
set -e

if [ ! -f pubspec.yaml ]; then
  echo "Run this from inside your repo root (where pubspec.yaml lives)."
  exit 1
fi

mkdir -p "lib/features/home"
cat > "lib/features/home/home_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/providers.dart';
import '../../shared/widgets/limit_ring.dart';
import '../../shared/widgets/trend_chart.dart';
import '../../shared/widgets/pressable_scale.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only this value rebuilds on DB change — everything else on the
    // screen is const or driven by its own narrow provider, so a
    // usage-row insert never repaints the whole page.
    final screenTime = ref.watch(todayScreenTimeProvider);

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topCenter,
          radius: 1.15,
          colors: [Color(0x3A8B7FE8), Colors.transparent],
          stops: [0.0, 0.6],
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
          children: [
            const _Header(),
            const SizedBox(height: 18),

            const _LimitScoreBanner(score: 475, tier: 'Focused'),
            const SizedBox(height: 22),

            Center(
              child: screenTime.when(
                data: (used) => _ScreenTimeRing(used: used, budget: const Duration(hours: 4)),
                loading: () => const LimitRing(progress: 0, size: 122, trackColor: AppColors.stroke),
                error: (_, __) => const Icon(Icons.error_outline, color: AppColors.danger),
              ),
            ),
            const SizedBox(height: 28),

            const _SectionLabel('THIS WEEK'),
            const SizedBox(height: 10),
            const _WeeklyTrendCard(),
            const SizedBox(height: 10),
            const Row(
              children: [
                Expanded(
                  child: _MiniTrendCard(
                    label: 'Focus time',
                    value: '11h 20m',
                    delta: '▲ 12%',
                    deltaGood: true,
                    values: [4, 5, 4.5, 7, 6, 8.5, 9],
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: _MiniTrendCard(
                    label: 'Pickups / day',
                    value: '48',
                    delta: '▼ 9%',
                    deltaGood: true,
                    values: [58, 55, 56, 48, 50, 44, 48],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),

            const _SectionLabel('CONTROLS'),
            const SizedBox(height: 10),
            const _ControlsGrid(),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Today', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text(_formattedDate(), style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        // Streak chip moved into the header row itself — reads as a
        // status badge rather than a floating pill competing with the
        // ring for attention below.
        const _StreakBadge(days: 4),
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

class _StreakBadge extends StatelessWidget {
  const _StreakBadge({required this.days});
  final int days;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_fire_department_rounded, size: 13, color: AppColors.accentSoft),
          const SizedBox(width: 5),
          Text('$days day streak',
              style: const TextStyle(fontSize: 11, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.labelSmall);
}

class _ScreenTimeRing extends StatelessWidget {
  const _ScreenTimeRing({required this.used, required this.budget});
  final Duration used;
  final Duration budget;

  @override
  Widget build(BuildContext context) {
    final remaining = budget - used;
    final progress = 1 - (used.inSeconds / budget.inSeconds).clamp(0.0, 1.0);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: progress),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => Container(
        // A soft glow behind the ring is what actually reads as
        // "premium" in a dark UI — cheap: one BoxShadow, not a blurred
        // duplicate layer.
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppColors.accent.withOpacity(0.18),
              blurRadius: 40,
              spreadRadius: 4,
            ),
          ],
        ),
        child: LimitRing(
          progress: value,
          size: 130,
          strokeWidth: 9,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_formatDuration(remaining), style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text('LEFT TODAY', style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
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
    return PressableScale(
      onTap: () {}, // wire to Routes.score detail push
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.stroke),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [AppColors.accent.withOpacity(0.14), AppColors.surface],
            stops: const [0.0, 0.65],
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
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
                      Text('$score',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 6),
                      Text('Limit',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600, color: AppColors.inkDim)),
                    ],
                  ),
                  Text('$tier tier · 25 to next badge', style: Theme.of(context).textTheme.bodySmall),
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

class _WeeklyTrendCard extends StatelessWidget {
  const _WeeklyTrendCard();

  static const _values = [3.8, 3.2, 3.9, 2.6, 2.9, 2.1, 1.9]; // hours, Mon→Sun

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Avg. daily screen time',
                  style: TextStyle(fontSize: 12, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
              Text('▼ 18% vs last week',
                  style: TextStyle(fontSize: 11, color: AppColors.accentSoft, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 2),
          Text('3h 12m', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const TrendAreaChart(values: _values),
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
    required this.value,
    required this.delta,
    required this.deltaGood,
    required this.values,
  });

  final String label;
  final String value;
  final String delta;
  final bool deltaGood;
  final List<double> values;

  @override
  Widget build(BuildContext context) {
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
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Sparkline(values: values),
          const SizedBox(height: 6),
          Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(delta, style: TextStyle(fontSize: 10, color: deltaGood ? AppColors.accentSoft : AppColors.inkFaint)),
        ],
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
    return PressableScale(
      onTap: () {}, // wire to each tile's detail route
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
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
    );
  }
}
PATCH_EOF

git add -A
git -c user.email="dev@ulimit.app" -c user.name="Ulimit Dev" commit -m "Fix flutter analyze: prefer_const_constructors in weekly trend card header"
git push

echo "Pushed. Removing this script."
rm -- "$0"
