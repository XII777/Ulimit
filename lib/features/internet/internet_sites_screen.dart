import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/icons/app_icons.dart';
import '../../core/native/enforcement_channel.dart';
import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/apps_repository.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../data/website_providers.dart';
import '../../shared/widgets/app_selector.dart';
import '../../shared/widgets/app_sheet.dart';
import '../../shared/widgets/pressable_scale.dart';
import '../../shared/widgets/search_field.dart';
import '../../shared/widgets/spring_scroll.dart';

/// Internet & Sites: local VPN protection plus three swipeable columns —
/// Filters (downloadable block lists), Custom (hand-added domains) and
/// Apps (per-app internet blocking) — driven by one wide search bar and
/// a floating action pill that morphs into a plus button whenever the
/// typed text is not in the visible list.
class InternetSitesScreen extends ConsumerStatefulWidget {
  const InternetSitesScreen({super.key});

  @override
  ConsumerState<InternetSitesScreen> createState() => _InternetSitesScreenState();
}

class _InternetSitesScreenState extends ConsumerState<InternetSitesScreen>
    with WidgetsBindingObserver {
  final PageController _pageController = PageController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';
  int _column = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // VPN state can change while backgrounded; refresh on resume.
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(vpnStatusProvider);
    }
  }

  void _onSearchChanged() {
    setState(() => _query = _searchController.text);
  }

  void _goToColumn(int index) {
    FocusScope.of(context).unfocus();
    if (index == _column) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  void _onPageChanged(int page) {
    setState(() => _column = page);
    // Each column gets a fresh search context.
    if (_searchController.text.isNotEmpty) _searchController.clear();
    FocusScope.of(context).unfocus();
  }

  // -- Floating action ------------------------------------------------------

  Future<void> _addTypedDomain() async {
    final ok = await ref.read(databaseProvider).addCustomDomain(_query);
    if (!ok) {
      if (mounted) showAppSnack(context, 'Enter a valid domain, e.g. example.com');
      return;
    }
    ref.read(enforcementSyncProvider).push();
    if (mounted) {
      _searchController.clear();
      FocusScope.of(context).unfocus();
    }
  }

  Future<void> _openAppPicker({String withQuery = ''}) async {
    // Multi-select: pick one or many apps, all get blocked on Done.
    final result = await showAppSelector(
      context,
      title: 'Block internet for',
      multiSelect: true,
      initialQuery: withQuery,
    );
    if (result is! Set || result.isEmpty) return;
    final db = ref.read(databaseProvider);
    for (final pkg in result) {
      await db.setInternetBlocked(pkg as String, true);
    }
    ref.read(enforcementSyncProvider).push();
  }

  /// Resolves the plus button for the visible column. On Custom it is
  /// ALWAYS present (the user's request): with a valid domain typed it
  /// adds it, otherwise it uplifts the keyboard to type one. On Apps it
  /// opens the picker. Hidden on Filters (downloads are per-list).
  ({bool visible, VoidCallback? onTap}) _resolveFab() {
    final q = _query.trim();

    if (_column == 1) {
      final domain = normalizeDomain(q);
      if (domain.isNotEmpty) {
        return (visible: true, onTap: _addTypedDomain);
      }
      return (visible: true, onTap: _focusSearchForDomain);
    }

    if (_column == 2) {
      final blocks = ref.watch(internetBlocksProvider).valueOrNull ?? const <InternetBlock>[];
      final catalog = ref.watch(appsCatalogProvider).valueOrNull;
      final present = blocks.any((b) =>
          (catalog?.nameFor(b.packageName) ?? b.packageName).toLowerCase().contains(q.toLowerCase()));
      if (q.isNotEmpty && !present) {
        return (visible: true, onTap: () => _openAppPicker(withQuery: q));
      }
      return (visible: true, onTap: () => _openAppPicker());
    }

    // Filters column: downloads happen per-list, no add action.
    return (visible: false, onTap: null);
  }

  /// Empty/garbage domain typed: focus the search bar and tell the user
  /// what the plus is waiting for.
  void _focusSearchForDomain() {
    _searchFocus.requestFocus();
    if (mounted) {
      showAppSnack(context, 'Type a domain (example.com) and tap + to block it.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final fab = _resolveFab();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        // Full-width floating layout: lists scroll all the way down, and
        // the SEARCH pill + plus hover over them at the bottom edge with
        // NO panel behind them — the page background shows through.
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: PremiumHeader(
                    title: 'Internet & Sites',
                    subtitle: 'Local, on-device filtering — no remote proxy',
                  ),
                ),
                const SizedBox(height: 18),
                const _VpnCard(),
                const SizedBox(height: 14),
                // Column selector (Filters / Custom / Apps) — own row,
                // just under Protection.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    height: 48,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 250,
                        child: _ColumnPills(
                          controller: _pageController,
                          activeIndex: _column,
                          onTap: _goToColumn,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: _onPageChanged,
                    children: [
                      _FiltersColumn(query: _query),
                      _CustomColumn(query: _query),
                      _AppsColumn(query: _query),
                    ],
                  ),
                ),
              ],
            ),
            // ---------------- the floating bottom bar ----------------
            // FULL-BLEED: the bar spans the whole screen width; the
            // search pill + plus float over it. NO width animation:
            // the field is full width and the plus overlays its right
            // end — a 340 ms AnimatedContainer width here re-layouted
            // the text every frame (the typing/tab jank). The hint
            // clearance switch is a single relayout per tab change.
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 10,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  height: 50,
                  child: Stack(
                    alignment: Alignment.centerRight,
                    children: [
                      AppSearchField(
                        controller: _searchController,
                        focusNode: _searchFocus,
                        hint: 'Search sites, filters or apps…',
                        textStyle: TextStyle(color: AppColors.ink, fontSize: 12),
                        hintStyle:
                            TextStyle(color: AppColors.inkFaint, fontSize: 12),
                        // Clears the plus's hit area with ONE relayout
                        // on tab switch — not a per-frame animation.
                        hintPaddingRight: fab.visible ? 66 : 0,
                      ),
                      // Plus — the lift/sink spring already lives inside
                      // _ActionFab; it rides the bar's right end.
                      _ActionFab(visible: fab.visible, onTap: fab.onTap),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Column pills
// ---------------------------------------------------------------------------

/// The three horizontal column selectors in one capsule. The ink
/// highlight is a single positioned layer that GLIDES continuously with
/// `controller.page` — taps animate the page (so pill and content move
/// in one eased motion, like an iOS segmented control), swipes track
/// the finger 1:1. No discrete hops, no per-frame color snapping.
class _ColumnPills extends StatelessWidget {
  const _ColumnPills({
    required this.controller,
    required this.activeIndex,
    required this.onTap,
  });

  final PageController controller;
  final int activeIndex;
  final ValueChanged<int> onTap;

  static const _labels = ['Filters', 'Custom', 'Apps'];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final page = controller.hasClients
            ? (controller.page ?? activeIndex.toDouble())
            : activeIndex.toDouble();
        final settled = page.round().clamp(0, _labels.length - 1);
        return Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: AppColors.stroke),
          ),
          child: LayoutBuilder(builder: (context, constraints) {
            // The LayoutBuilder sits inside the container's own 4px
            // padding — each slot is exactly a third of this width.
            final slotWidth = constraints.maxWidth / _labels.length;
            return SizedBox(
              height: 40,
              child: Stack(
                children: [
                  // The ink highlight: one layer, continuously eased to
                  // the page position — tap and swipe share one motion.
                  Positioned(
                    left: slotWidth * page.clamp(0.0, _labels.length - 1.0),
                    width: slotWidth,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.ink,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                  ),
                  // Hit targets + labels on top.
                  Row(
                    children: [
                      for (var i = 0; i < _labels.length; i++)
                        Expanded(
                          child: _PillLabel(
                            label: _labels[i],
                            active: i == settled,
                            onTap: () => onTap(i),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          }),
        );
      },
    );
  }
}

class _PillLabel extends StatelessWidget {
  const _PillLabel({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          style: TextStyle(
            // Match the bottom-nav labels exactly: 12 Semibold.
            fontSize: 12.0,
            fontWeight: FontWeight.w600,
            color: active ? AppColors.bg : AppColors.inkDim,
          ),
          child: Text(label, maxLines: 1),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Search bar
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// VPN
// ---------------------------------------------------------------------------

class _VpnCard extends ConsumerWidget {
  const _VpnCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(vpnStatusProvider);
    final running = status.valueOrNull?.running ?? false;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: PremiumCard(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: running ? AppColors.ink : AppColors.surface2,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: AppIcon(
                AppIconName.internet,
                size: 18,
                color: running ? AppColors.bg : AppColors.inkDim,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text('Protection',
                  style: TextStyle(
                      fontSize: AppText.title, fontWeight: FontWeight.w600, color: AppColors.ink)),
            ),
            Switch(
              value: running,
              onChanged: (v) async {
                if (v) {
                  final ok = await EnforcementChannel.startVpn();
                  if (ok) {
                    await ref.read(settingsControllerProvider).setVpnEnabled(true);
                  }
                  // Reflect the requested state even if the user must
                  // grant consent next launch; the permission card
                  // handles the consent flow.
                  if (!ok && context.mounted) {
                    showAppSnack(context, 'VPN permission required — approve it in Permissions.');
                  }
                } else {
                  await EnforcementChannel.stopVpn();
                  await ref.read(settingsControllerProvider).setVpnEnabled(false);
                }
                ref.invalidate(vpnStatusProvider);
                // Re-sync the domain filter with the new VPN session.
                ref.read(enforcementSyncProvider).push();
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Column 1 — Filters: downloadable block lists
// ---------------------------------------------------------------------------

class _FiltersColumn extends ConsumerWidget {
  const _FiltersColumn({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(blockListCategoriesProvider);

    return categories.when(
      data: (list) {
        final q = query.trim().toLowerCase();
        // Site search across DOWNLOADED lists: matches render inline,
        // grouped under their parent category heading.
        final siteHits = ref.watch(filterSiteSearchProvider(query)).valueOrNull ?? const {};
        final showSiteHits = q.length >= 2 && siteHits.isNotEmpty;

        // Ordering: ACTIVE (downloaded + enabled) lists first, then
        // DOWNLOADED-but-off, then everything NOT DOWNLOADED.
        final ordered = [
          ...list.where((v) => v.downloaded && v.enabled),
          ...list.where((v) => v.downloaded && !v.enabled),
          ...list.where((v) => !v.downloaded),
        ];
        if (ordered.isEmpty && !showSiteHits) {
          return ListView(
            physics: springScrollPhysics,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 96),
            children: const [_EmptyHint(text: 'No filters match this search')],
          );
        }
        return ListView(
          physics: springScrollPhysics,
          padding: EdgeInsets.fromLTRB(20, showSiteHits ? 4 : 18, 20, 96),
          children: [
              if (showSiteHits) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: _SectionLabel('SITE MATCHES'),
              ),
              for (final view in ordered.where((v) => siteHits.containsKey(v.template.id))) ...[
                _CategoryMatchGroup(view: view, rules: siteHits[view.template.id]!),
                const SizedBox(height: 12),
              ],
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 8, 4, 8),
                child: _SectionLabel('FILTER LISTS'),
              ),
            ],
            for (final view in ordered)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _BlockListTile(view: view),
              ),
          ],
        );
      },
      loading: () => const _ColumnSpinner(),
      error: (e, _) => _ColumnError(message: 'Could not load filters: $e'),
    );
  }
}

/// One category's site-search matches: a small heading (category name,
/// tap = open the full category browser) and the matched site rows.
class _CategoryMatchGroup extends StatelessWidget {
  const _CategoryMatchGroup({required this.view, required this.rules});
  final BlockListCategoryView view;
  final List<WebsiteRule> rules;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: view.downloaded
                ? () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _CategorySitesScreen(view: view),
                      ),
                    )
                : null,
            child: Row(
              children: [
                Flexible(
                  child: Text(view.template.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.ink)),
                ),
                const SizedBox(width: 6),
                AppIcon(AppIconName.chevronRight, size: 11, color: AppColors.inkFaint),
              ],
            ),
          ),
          const SizedBox(height: 4),
          for (final rule in rules)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _SiteTile(rule: rule, dense: true),
            ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
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

// ---------------------------------------------------------------------------
// Column 2 — Custom: manually added domains
// ---------------------------------------------------------------------------

class _CustomColumn extends ConsumerWidget {
  const _CustomColumn({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(customWebsiteRulesProvider);

    return rules.when(
      data: (rows) {
        final q = query.trim().toLowerCase();
        final filtered = rows
            .where((r) => q.isEmpty || r.domain.toLowerCase().contains(q))
            .toList();
        if (filtered.isEmpty) {
          return ListView(
            physics: springScrollPhysics,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 96),
            children: [
              _EmptyHint(
                text: q.isEmpty
                    ? 'No custom sites yet.\nType a domain in the search bar and tap + to add it.'
                    : 'No custom sites match this search',
              ),
            ],
          );
        }
        return ListView.builder(
          physics: springScrollPhysics,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 96),
          itemCount: filtered.length,
          // Breathing room between toggle rows so switches never crowd.
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SiteTile(rule: filtered[i]),
          ),
        );
      },
      loading: () => const _ColumnSpinner(),
      error: (e, _) => _ColumnError(message: 'Could not load sites: $e'),
    );
  }
}

// ---------------------------------------------------------------------------
// Column 3 — Apps: per-app internet blocks
// ---------------------------------------------------------------------------

class _AppsColumn extends ConsumerWidget {
  const _AppsColumn({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks = ref.watch(internetBlocksProvider);
    final catalog = ref.watch(appsCatalogProvider);

    return blocks.when(
      data: (rows) {
        final q = query.trim().toLowerCase();
        final filtered = rows
            .where((r) =>
                q.isEmpty ||
                (catalog.valueOrNull?.nameFor(r.packageName) ?? r.packageName)
                    .toLowerCase()
                    .contains(q))
            .toList();
        if (filtered.isEmpty) {
          return ListView(
            physics: springScrollPhysics,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 96),
            children: [
              _EmptyHint(
                text: q.isEmpty
                    ? 'No apps blocked from the internet yet.\nTap "Add app" to pick one.'
                    : 'No apps match this search',
              ),
            ],
          );
        }
        return ListView.builder(
          physics: springScrollPhysics,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 96),
          itemCount: filtered.length,
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _InternetBlockRow(
              packageName: filtered[i].packageName,
              appName:
                  catalog.valueOrNull?.nameFor(filtered[i].packageName) ?? filtered[i].packageName,
            ),
          ),
        );
      },
      loading: () => const _ColumnSpinner(),
      error: (e, _) => _ColumnError(message: 'Could not load apps: $e'),
    );
  }
}

// ---------------------------------------------------------------------------
// Column scaffolding
// ---------------------------------------------------------------------------

class _ColumnSpinner extends StatelessWidget {
  const _ColumnSpinner();

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator(strokeWidth: 2));
}

class _ColumnError extends StatelessWidget {
  const _ColumnError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.inkFaint)),
        ),
      );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: AppColors.inkFaint, height: 1.5),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Floating plus button
// ---------------------------------------------------------------------------

/// The plus, riding at the end of the control line. Uplifts on its
/// condition: it springs up from the line (slide + scale + fade under
/// one eased curve) when the visible column has an add action, and
/// sinks back when it has none.
class _ActionFab extends StatelessWidget {
  const _ActionFab({required this.visible, this.onTap});

  final bool visible;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          // Uplift: springs out of the control line (½ circle ≈ 18px
          // of travel) instead of popping in place.
          offset: visible ? Offset.zero : const Offset(0, 0.4),
          duration: const Duration(milliseconds: 340),
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: visible ? 1.0 : 0.6,
            duration: const Duration(milliseconds: 340),
            curve: Curves.easeOutBack,
            child: PressableScale(
              onTap: visible ? onTap : null,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.ink,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.30),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: AppIcon(AppIconName.add, size: 22, color: AppColors.bg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

class _InternetBlockRow extends ConsumerWidget {
  const _InternetBlockRow({required this.packageName, required this.appName});
  final String packageName;
  final String appName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      // Generous vertical padding so the row never reads compact.
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          AppIconView(packageName: packageName, size: 40, radius: 10),
          const SizedBox(width: 14),
          Expanded(
            child: Text(appName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppText.body, color: AppColors.ink)),
          ),
          // Rows only exist for blocked apps, so the toggle is always
          // on — flipping it off removes the internet block.
          Switch(
            value: true,
            onChanged: (v) async {
              if (v) return;
              await ref.read(databaseProvider).setInternetBlocked(packageName, false);
              ref.read(enforcementSyncProvider).push();
            },
            activeTrackColor: AppColors.ink,
            activeThumbColor: AppColors.bg,
          ),
        ],
      ),
    );
  }
}

/// The per-site row: a long horizontal tile with no border — domain on
/// the left, its own enable/disable toggle on the right. Used for every
/// site in every list (custom + downloaded categories).
class _SiteTile extends ConsumerWidget {
  const _SiteTile({required this.rule, this.dense = false});
  final WebsiteRule rule;

  /// Compact variant for rows inside a search-match group.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 0 : 6),
      child: Row(
        children: [
          const SizedBox(width: 4),
          AppIcon(AppIconName.link, size: 13, color: AppColors.inkFaint),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              rule.domain,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: dense ? 12.5 : 13,
                color: rule.enabled ? AppColors.ink : AppColors.inkFaint,
              ),
            ),
          ),
          SizedBox(
            height: dense ? 32 : null,
            child: Switch(
              value: rule.enabled,
              onChanged: (v) {
                ref.read(databaseProvider).setRuleEnabled(rule.id, v);
                ref.read(enforcementSyncProvider).push();
              },
              activeTrackColor: AppColors.ink,
              activeThumbColor: AppColors.bg,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Block lists
// ---------------------------------------------------------------------------

class _BlockListTile extends ConsumerWidget {
  const _BlockListTile({required this.view});
  final BlockListCategoryView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final template = view.template;
    final state = ref.watch(blockListDownloadStateProvider(template.id));

    return Container(
      // Long horizontal tile, no border — per the design direction for
      // block-list entries. Surface color only.
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          Expanded(
            // Tap = open the site browser. LONG-PRESS = the remove
            // bottom sheet (replaces the old "View sites"/"Remove list"
            // text links).
            child: GestureDetector(
              onLongPress: () => _showRemoveSheet(context, ref),
              onTap: view.downloaded ? () => _openSites(context, ref) : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(template.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.ink)),
                      ),
                      if (template.recommended) ...[
                        const SizedBox(width: 6),
                        Text('RECOMMENDED',
                            style: TextStyle(fontSize: 8.5, letterSpacing: 0.5, color: AppColors.inkFaint)),
                      ],
                      if (view.locked) ...[
                        const SizedBox(width: 6),
                        AppIcon(AppIconName.lock, size: 11, color: AppColors.inkDim),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    template.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: AppColors.inkFaint, height: 1.4),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    view.downloaded
                        ? '${view.siteCount} sites · downloaded '
                            '${_fmtDate(view.downloadedAt)}${view.enabled ? '' : ' · filter off'}'
                        : '~${_fmtCount(template.approxEntries)} sites · not downloaded',
                    style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          _buildAction(context, ref, state),
        ],
      ),
    );
  }

  Widget _buildAction(BuildContext context, WidgetRef ref, BlockListDownloadState state) {
    if (state == BlockListDownloadState.downloading) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    if (!view.downloaded) {
      return GestureDetector(
        onTap: () => _download(context, ref),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.ink,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text('Download',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.bg)),
        ),
      );
    }

    // Category enable toggle — for one-way categories this is the
    // "lock" moment, confirmed by an irreversible dialog.
    return Switch(
      value: view.enabled,
      onChanged: view.locked
          ? null // locked: cannot be disabled anymore
          : (v) => _setEnabled(context, ref, v),
    );
  }

  /// Long-press bottom sheet: the download/remove surface for a
  /// downloaded list (locked lists explain why they can't be removed).
  Future<void> _showRemoveSheet(BuildContext context, WidgetRef ref) async {
    if (!view.downloaded) return;
    final template = view.template;

    if (view.locked || template.id == 'adult') {
      await showAppSheet<void>(
        context: context,
        title: template.title,
        builder: (sheetContext, _) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Text(
            'This filter is locked. Once adult-content blocking is on, the '
            'list cannot be removed from this device.',
            style: TextStyle(fontSize: 12.5, color: AppColors.inkDim, height: 1.5),
          ),
        ),
      );
      return;
    }

    final confirmed = await showAppConfirmSheet(
      context,
      title: 'Remove "${template.title}"?',
      message: 'All ${template.title} sites and their toggles will be deleted.',
      confirmLabel: 'Remove',
    );
    if (confirmed == true) {
      await ref.read(blockListRepositoryProvider).removeCategory(template.id);
      ref.read(enforcementSyncProvider).push();
    }
  }

  Future<void> _download(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(blockListDownloadStateProvider(view.template.id).notifier);
    notifier.state = BlockListDownloadState.downloading;
    try {
      await ref.read(blockListRepositoryProvider).download(view.template.id);
      notifier.state = BlockListDownloadState.done;
    } catch (e) {
      notifier.state = BlockListDownloadState.failed;
      if (context.mounted) {
        showAppSnack(context, 'Download failed — check your connection.');
      }
    }
    ref.read(enforcementSyncProvider).push();
  }

  Future<void> _setEnabled(BuildContext context, WidgetRef ref, bool enabled) async {
    if (enabled && view.template.locksAfterEnable) {
      final confirmed = await showAppConfirmSheet(
        context,
        title: 'This cannot be undone',
        message: 'Once adult-content blocking is turned on, it cannot be turned '
            'off again. The list will keep blocking adult sites on this '
            'device. Individual sites inside the list can still be '
            'toggled, but the filter itself stays on permanently.',
        confirmLabel: 'Turn on permanently',
        // Irreversible action — a stray tap on the dim background must
        // not close the warning; an explicit Cancel / drag-down is the
        // way out (matches the previous barrierDismissible: false).
        isDismissible: false,
      );
      if (confirmed != true) return;
    }

    await ref.read(blockListRepositoryProvider).setCategoryEnabled(view.template.id, enabled);
    ref.read(enforcementSyncProvider).push();
  }

  void _openSites(BuildContext context, WidgetRef ref) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _CategorySitesScreen(view: view),
      ),
    );
  }

  String _fmtCount(int n) {
    if (n >= 1000) return '${(n / 1000).round()}k';
    return '$n';
  }

  String _fmtDate(DateTime? dt) {
    if (dt == null) return '';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${dt.day} ${months[dt.month - 1]}';
  }
}

// ---------------------------------------------------------------------------
// Category site browser (search + per-site toggles)
// ---------------------------------------------------------------------------

class _CategorySitesScreen extends ConsumerStatefulWidget {
  const _CategorySitesScreen({required this.view});
  final BlockListCategoryView view;

  @override
  ConsumerState<_CategorySitesScreen> createState() => _CategorySitesScreenState();
}

class _CategorySitesScreenState extends ConsumerState<_CategorySitesScreen> {
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sites = ref.watch(siteSearchProvider((widget.view.template.id, _query)));

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
                        Text(widget.view.template.title,
                            style: TextStyle(
                                fontSize: AppText.headline, fontWeight: FontWeight.w600, color: AppColors.ink)),
                        Text('${widget.view.siteCount} sites',
                            style: TextStyle(fontSize: AppText.caption, color: AppColors.inkDim)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: AppSearchField(
                hint: 'Search ${widget.view.template.title.toLowerCase()} sites…',
                onChanged: (v) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 250), () {
                    setState(() => _query = v);
                  });
                },
              ),
            ),
            Expanded(
              child: sites.when(
                data: (rows) {
                  if (rows.isEmpty) {
                    return Center(
                      child: Text('No sites match this search',
                          style: TextStyle(fontSize: 12.5, color: AppColors.inkFaint)),
                    );
                  }
                  return ListView.builder(
                    physics: springScrollPhysics,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _SiteTile(rule: rows[i]),
                    ),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                error: (e, _) => Center(
                  child: Text('Could not load sites: $e',
                      style: TextStyle(fontSize: 12, color: AppColors.inkFaint)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
