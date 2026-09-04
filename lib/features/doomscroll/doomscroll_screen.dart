import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/restriction_engine.dart';
import '../../core/icons/app_icons.dart';
import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/apps_repository.dart';
import '../../data/doomscroll_apps.dart';
import '../../data/doomscroll_providers.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../data/usage_tracker.dart';
import '../../shared/widgets/app_selector.dart';
import '../../shared/widgets/app_sheet.dart';
import '../../shared/widgets/spring_scroll.dart';
import '../../shared/widgets/trend_chart.dart';

/// Doomscroll analytics & per-platform rules.
///
/// Sections:
///  - Today: opens so far + time in feeds + budget pressure
///  - Weekly: opens line graph (TrendAreaChart) + weekday mini-bars
///  - Platforms: every major infinite-feed app with an enable switch
///    and a daily opens budget (0 = block outright)
///
/// Data source is the real per-day open counts UsageTracker persists —
/// the same numbers the notification chip counts and the engine enforces.
class DoomscrollScreen extends ConsumerWidget {
  const DoomscrollScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todayOpens = ref.watch(doomscrollTodayTotalProvider);
    final todaySeconds = ref.watch(doomscrollTodaySecondsProvider).valueOrNull ?? 0;
    final weekly = ref.watch(doomscrollWeeklyOpensProvider).valueOrNull;
    final platforms = ref.watch(doomscrollRulesProvider).valueOrNull;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
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
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Doomscroll',
                            style: TextStyle(
                                fontSize: AppText.headline,
                                fontWeight: FontWeight.w600,
                                color: AppColors.ink)),
                        Text('Infinite-feed analytics & budgets',
                            style: TextStyle(fontSize: AppText.caption, color: AppColors.inkDim)),
                      ],
                    ),
                  ),
                  // Diagnostics: when blocking "isn't working", this is
                  // the first place to look — the engine card checks the
                  // whole chain (snapshot, scroll events, marker hits,
                  // ejects, budget counters) and copies a report.
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    icon: AppIcon(AppIconName.stopwatch, size: 16, color: AppColors.inkDim),
                    tooltip: 'Diagnostics',
                    onPressed: () => GoRouter.of(context).push('/diagnostics'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                physics: springScrollPhysics,
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                children: [
                  _TodayCard(
                    opens: todayOpens,
                    seconds: todaySeconds,
                  ),
                  const SizedBox(height: 16),
                  _WeeklyCard(weekly: weekly),
                  const SizedBox(height: 16),
                  if (platforms == null)
                    const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    _PlatformsCard(platforms: platforms),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'Section apps (Instagram, YouTube…) keep working — only '
                      'the Reels/Shorts/For-You scroll is detected and ejected. '
                      'Feed apps (Reddit, Pinterest…) are the feed itself: their '
                      'budget blocks the app. One open = every time you enter a '
                      'feed.',
                      style: TextStyle(
                          fontSize: 10.5, height: 1.5, color: AppColors.inkFaint),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Today
// ---------------------------------------------------------------------------

class _TodayCard extends ConsumerStatefulWidget {
  const _TodayCard({required this.opens, required this.seconds});

  final int opens;
  final int seconds;

  @override
  ConsumerState<_TodayCard> createState() => _TodayCardState();
}

class _TodayCardState extends ConsumerState<_TodayCard> {
  /// Set on every native scroll-session sentinel and cleared 2.5s after
  /// the last one — the "counting right now" pulse. Watching the
  /// notifier (not the DB stream alone) makes the flash frame-accurate:
  /// a session landed THIS second, the number you see just rolled.
  bool _pulsing = false;

  @override
  void initState() {
    super.initState();
    UsageTracker.doomSessionTick.addListener(_onTick);
  }

  @override
  void dispose() {
    UsageTracker.doomSessionTick.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (UsageTracker.doomSessionTick.value == null) return;
    if (mounted) setState(() => _pulsing = true);
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _pulsing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final liveActive = ref.watch(doomscrollLiveActiveProvider);
    final showPulse = liveActive || _pulsing;

    return PremiumCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(AppIconName.userBlock, size: 14, color: AppColors.inkDim),
              const SizedBox(width: 7),
              Expanded(
                child: Text('Today',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
              ),
              if (showPulse)
                AnimatedOpacity(
                  opacity: 1,
                  duration: const Duration(milliseconds: 220),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _pulsing ? AppColors.ink : AppColors.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      border: Border.all(
                          color: _pulsing ? AppColors.ink : AppColors.stroke),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Counting RIGHT NOW: bright dot; inside a feed
                        // but idle between sessions: dim outline dot.
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: _pulsing
                                ? AppColors.bg
                                : Colors.transparent,
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: _pulsing ? AppColors.bg : AppColors.inkDim,
                                width: 1.5),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _pulsing ? 'counting…' : 'scrolling',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: _pulsing ? AppColors.bg : AppColors.inkDim),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Live roll: each scroll session swaps the number in with
              // a slide-up + fade — the counter visibly moves while the
              // user doomscrolls instead of waiting for a refresh.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.35),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: Text('${widget.opens}',
                    key: ValueKey(widget.opens),
                    style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w600,
                        color: AppColors.ink,
                        height: 1)),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('scrolls in feeds today',
                    style: TextStyle(fontSize: 11.5, color: AppColors.inkDim)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(formatDurationShort(Duration(seconds: widget.seconds)) + ' spent in feeds',
              style: TextStyle(fontSize: 11, color: AppColors.inkFaint)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Weekly line graph
// ---------------------------------------------------------------------------

class _WeeklyCard extends StatelessWidget {
  const _WeeklyCard({required this.weekly});

  final List<DoomscrollDay>? weekly;

  @override
  Widget build(BuildContext context) {
    final days = weekly;
    if (days == null) {
      return PremiumCard(
        padding: const EdgeInsets.all(16),
        child: const SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }

    final opens = [for (final d in days) d.seconds.toDouble()];
    final totalOpens = days.fold<int>(0, (a, b) => a + b.opens);
    final avg = totalOpens / 7;
    final maxDay = days.fold<int>(0, (m, d) => d.opens > m ? d.opens : m);

    return PremiumCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(AppIconName.trend, size: 14, color: AppColors.inkDim),
              const SizedBox(width: 7),
              Expanded(
                child: Text('This week',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
              ),
              Text('$totalOpens scrolls · ${avg.toStringAsFixed(1)}/day',
                  style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint)),
            ],
          ),
          const SizedBox(height: 14),
          // The opens line graph — same CustomPainter chart the dashboards
          // use; opens are discrete counts so the line reads honestly.
          TrendAreaChart(
            values: opens,
            height: 88,
            color: AppColors.ink,
            showAverageLine: totalOpens > 0,
          ),
          const SizedBox(height: 6),
          // Weekday letters aligned under the line's 7 points.
          Row(
            children: [
              for (final letter in _weekLetters(days))
                Expanded(
                  child: Text(letter,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 9, color: AppColors.inkFaint)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // Per-day count row — the numbers behind the line.
          Row(
            children: [
              for (final d in days)
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '${d.opens}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: d.opens == maxDay && maxDay > 0
                              ? AppColors.ink
                              : AppColors.inkFaint,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static List<String> _weekLetters(List<DoomscrollDay> days) {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return [for (final d in days) letters[d.day.weekday - 1]];
  }
}

// ---------------------------------------------------------------------------
// Platforms — pick which to block + daily opens budget
// ---------------------------------------------------------------------------

class _PlatformsCard extends ConsumerWidget {
  const _PlatformsCard({required this.platforms});

  final List<DoomscrollRule> platforms;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(appsCatalogProvider).valueOrNull;
    final todayCounts = ref.watch(doomscrollTodayCountsProvider).valueOrNull ?? const {};
    final ruleByPackage = {for (final r in platforms) r.packageName: r};

    // Installed platforms first, then the rest — ordering follows the
    // canonical preset order within each group.
    final installed = kDoomscrollPlatforms
        .where((p) => catalog?.byPackage.containsKey(p.packageName) ?? false)
        .toList();
    final notInstalled =
        kDoomscrollPlatforms.where((p) => !installed.contains(p)).toList();
    final ordered = [...installed, ...notInstalled];

    final enabledCount = platforms.where((r) => r.enabled).length;

    return PremiumCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(AppIconName.block, size: 14, color: AppColors.inkDim),
              const SizedBox(width: 7),
              Expanded(
                child: Text('PLATFORMS',
                    style: TextStyle(
                        fontSize: AppText.overline,
                        color: AppColors.inkDim,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6)),
              ),
              Text('$enabledCount of ${kDoomscrollPlatforms.length} managed',
                  style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint)),
            ],
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < ordered.length; i++) ...[
            if (i > 0) Divider(height: 1, color: AppColors.stroke),
            _PlatformRow(
              platform: ordered[i],
              rule: ruleByPackage[ordered[i].packageName],
              installed: i < installed.length,
              opensToday: todayCounts[ordered[i].packageName] ?? 0,
            ),
          ],
        ],
      ),
    );
  }
}

class _PlatformRow extends ConsumerWidget {
  const _PlatformRow({
    required this.platform,
    required this.rule,
    required this.installed,
    required this.opensToday,
  });

  final DoomscrollPlatform platform;
  final DoomscrollRule? rule;
  final bool installed;
  final int opensToday;

  bool get _enabled => rule?.enabled ?? false;
  int get _budget => rule?.dailyOpenLimit ?? 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blockedNow =
        ref.watch(restrictionDecisionsProvider)[platform.packageName]?.appBlocked ?? false;

    return InkWell(
      onTap: () => _openBudgetSheet(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            AppIconView(packageName: platform.packageName, size: 26, radius: 7),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          platform.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color:
                                installed ? AppColors.ink : AppColors.inkFaint,
                          ),
                        ),
                      ),
                      if (blockedNow) ...[
                        const SizedBox(width: 6),
                        Text('blocked',
                            style: TextStyle(fontSize: 9.5, color: AppColors.inkFaint)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    !_enabled
                        ? 'Not managed'
                        : _budget == 0
                            ? (platform.sectionLevel
                                ? 'Reels blocked outright — app stays usable'
                                : 'Blocked outright')
                            : (platform.sectionLevel
                                ? '$_budget scrolls/day — reels eject past that'
                                : '$_budget scrolls/day, then blocked'),
                    style: TextStyle(fontSize: 10.5, color: AppColors.inkDim),
                  ),
                ],
              ),
            ),
            // Today's count — the number this row's budget is judged on.
            Text(
              '$opensToday',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: opensToday > 0 ? AppColors.ink : AppColors.inkFaint,
              ),
            ),
            const SizedBox(width: 10),
            Switch(
              value: _enabled,
              onChanged: (v) => _toggle(ref, v),
              activeTrackColor: AppColors.ink,
              activeColor: AppColors.bg,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggle(WidgetRef ref, bool enabled) async {
    final db = ref.read(databaseProvider);
    await db.setDoomscrollPlatform(
      packageName: platform.packageName,
      enabled: enabled,
      dailyOpenLimit: _budget,
    );
  }

  /// The per-platform budget sheet: manage on/off + daily opens budget
  /// with quick presets. 0 = block outright.
  Future<void> _openBudgetSheet(BuildContext context, WidgetRef ref) async {
    final db = ref.read(databaseProvider);
    await showAppSheet<void>(
      context: context,
      title: platform.name,
      subtitle: platform.feedLabel,
      builder: (sheetContext, scrollController) => _BudgetSheetBody(
        platform: platform,
        initialEnabled: _enabled,
        initialBudget: _budget,
        scrollController: scrollController,
        onSave: (enabled, budget) async {
          await db.setDoomscrollPlatform(
            packageName: platform.packageName,
            enabled: enabled,
            dailyOpenLimit: budget,
          );
        },
      ),
    );
  }
}

class _BudgetSheetBody extends StatefulWidget {
  const _BudgetSheetBody({
    required this.platform,
    required this.initialEnabled,
    required this.initialBudget,
    required this.scrollController,
    required this.onSave,
  });

  final DoomscrollPlatform platform;
  final bool initialEnabled;
  final int initialBudget;
  final ScrollController scrollController;
  final Future<void> Function(bool enabled, int budget) onSave;

  @override
  State<_BudgetSheetBody> createState() => _BudgetSheetBodyState();
}

class _BudgetSheetBodyState extends State<_BudgetSheetBody> {
  late bool _enabled = widget.initialEnabled;
  late int _budget = widget.initialBudget;
  bool _saving = false;

  // The unit is live SCROLL SESSIONS (one per fling burst; a 600ms
  // pause starts a new one) — so the useful range is much larger than
  // the old per-entry budget.
  static const _presets = [0, 25, 60, 120, 240, 480];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: widget.scrollController,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            activeTrackColor: AppColors.ink,
            activeColor: AppColors.bg,
            title: Text('Manage this platform',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.ink)),
            subtitle: Text(
              _enabled
                  ? (_budget == 0
                      ? (widget.platform.sectionLevel
                          ? 'Feed blocked outright — app stays usable'
                          : 'Blocked outright')
                      : 'Blocked after $_budget scrolls/day')
                  : 'Counted, but never blocked',
              style: TextStyle(fontSize: 11, color: AppColors.inkDim),
            ),
          ),
          const SizedBox(height: 6),
          Text('DAILY SCROLL BUDGET',
              style: TextStyle(
                  fontSize: AppText.overline,
                  color: AppColors.inkFaint,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in _presets)
                GestureDetector(
                  onTap: () => setState(() => _budget = preset),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: _budget == preset ? AppColors.ink : AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      border: Border.all(
                          color: _budget == preset ? AppColors.ink : AppColors.stroke),
                    ),
                    child: Text(
                      preset == 0 ? 'Block' : '$preset',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: _budget == preset ? AppColors.bg : AppColors.inkDim,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            widget.platform.sectionLevel
                ? 'Ulimit detects the ${widget.platform.feedLabel.toLowerCase().replaceAll('sessions', 'surface')} inside the app and backs you out of it. The rest of the app — DMs, search, profile — stays fully usable.'
                : 'This app IS a feed: 0 blocks it outright; any other number blocks it for the rest of the day once you scroll that many times in it.',
            style: TextStyle(fontSize: 10.5, height: 1.5, color: AppColors.inkFaint),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 46,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.ink,
                foregroundColor: AppColors.bg,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
              ),
              child: _saving
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.bg))
                  : const Text('Save',
                      style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.onSave(_enabled, _budget);
    if (mounted) Navigator.of(context).pop();
  }
}
