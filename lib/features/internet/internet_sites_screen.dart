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
    final pkg = await showAppSelector(
      context,
      title: 'Block internet for',
      initialQuery: withQuery,
    );
    if (pkg is! String) return;
    await ref.read(databaseProvider).setInternetBlocked(pkg, true);
    ref.read(enforcementSyncProvider).push();
  }

  /// Resolves the floating action for the visible column. The pill only
  /// morphs into a plus when the typed text is NOT in the current list —
  /// on Custom that plus adds the domain directly, on Apps it opens the
  /// picker pre-filled with the query.
  ({String? label, bool plus, VoidCallback? onTap}) _resolveFab() {
    final q = _query.trim();

    if (_column == 1) {
      final rules = ref.watch(customWebsiteRulesProvider).valueOrNull ?? const <WebsiteRule>[];
      if (q.isEmpty) {
        return (label: 'Add site', plus: false, onTap: () => _searchFocus.requestFocus());
      }
      final present = rules.any((r) => r.domain.contains(q.toLowerCase()));
      final domain = normalizeDomain(q);
      if (!present && domain.isNotEmpty) {
        return (label: null, plus: true, onTap: _addTypedDomain);
      }
      // Present in the list, or not a plausible domain — nothing to add.
      return (label: null, plus: false, onTap: null);
    }

    if (_column == 2) {
      final blocks = ref.watch(internetBlocksProvider).valueOrNull ?? const <InternetBlock>[];
      final catalog = ref.watch(appsCatalogProvider).valueOrNull;
      final present = blocks.any((b) =>
          (catalog?.nameFor(b.packageName) ?? b.packageName).toLowerCase().contains(q.toLowerCase()));
      if (q.isNotEmpty && !present) {
        return (label: null, plus: true, onTap: () => _openAppPicker(withQuery: q));
      }
      return (label: 'Add app', plus: false, onTap: () => _openAppPicker());
    }

    // Filters column: downloads happen per-list, no add action.
    return (label: null, plus: false, onTap: null);
  }

  @override
  Widget build(BuildContext context) {
    final fab = _resolveFab();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
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
                const SizedBox(height: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _ColumnPills(
                          controller: _pageController,
                          activeIndex: _column,
                          onTap: _goToColumn,
                        ),
                      ),
                      // The pills and the search bar never touch.
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _SearchBar(
                          controller: _searchController,
                          focusNode: _searchFocus,
                        ),
                      ),
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
                ),
              ],
            ),
            // Floating above the nav pill, mirroring the snackbar inset.
            Positioned(
              right: 20,
              bottom: 96,
              child: _ActionFab(label: fab.label, plus: fab.plus, onTap: fab.onTap),
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

/// The three horizontal column selectors in one capsule. The ink-filled
/// pill tracks the swipe like the floating nav pill does, so tapping a
/// pill and swiping share one motion language.
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
        final flow = (page - settled).clamp(-0.5, 0.5);
        return Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: AppColors.stroke),
          ),
          child: Row(
            children: [
              for (var i = 0; i < _labels.length; i++)
                Expanded(
                  child: _Pill(
                    label: _labels[i],
                    active: i == settled,
                    flow: flow,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.active,
    required this.flow,
    required this.onTap,
  });

  final String label;
  final bool active;

  /// Fractional progress (-0.5..0.5) beyond the settled column: the
  /// pill group drifts a few px toward the swipe, then settles at 0.
  final double flow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Transform.translate(
        offset: Offset(10 * flow, 0),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? AppColors.ink : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? AppColors.bg : AppColors.inkDim,
            ),
            child: Text(label, maxLines: 1),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Search bar
// ---------------------------------------------------------------------------

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.focusNode});

  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      style: TextStyle(color: AppColors.ink, fontSize: 14),
      decoration: InputDecoration(
        hintText: 'Search sites, filters or apps…',
        hintStyle: TextStyle(color: AppColors.inkFaint, fontSize: 13),
        prefixIcon: Padding(
          padding: const EdgeInsets.all(12),
          child: AppIcon(AppIconName.search, size: 16, color: AppColors.inkFaint),
        ),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              icon: AppIcon(AppIconName.close, size: 15, color: AppColors.inkFaint),
              onPressed: controller.clear,
            );
          },
        ),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 13),
      ),
    );
  }
}

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
        final filtered = list
            .where((v) =>
                q.isEmpty ||
                v.template.title.toLowerCase().contains(q) ||
                v.template.description.toLowerCase().contains(q))
            .toList();
        // Active (downloaded + enabled) lists float to the top so the
        // column reads active-first.
        final ordered = [
          ...filtered.where((v) => v.downloaded && v.enabled),
          ...filtered.where((v) => !(v.downloaded && v.enabled)),
        ];
        if (ordered.isEmpty) {
          return ListView(
            physics: springScrollPhysics,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 160),
            children: const [_EmptyHint(text: 'No filters match this search')],
          );
        }
        return ListView.builder(
          physics: springScrollPhysics,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 160),
          itemCount: ordered.length,
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _BlockListTile(view: ordered[i]),
          ),
        );
      },
      loading: () => const _ColumnSpinner(),
      error: (e, _) => _ColumnError(message: 'Could not load filters: $e'),
    );
  }
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
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 160),
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
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 160),
          itemCount: filtered.length,
          itemBuilder: (context, i) => _SiteTile(rule: filtered[i]),
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
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 160),
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
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 160),
          itemCount: filtered.length,
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
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
// Floating action pill
// ---------------------------------------------------------------------------

/// The floating action: a labeled pill ("Add app" / "Add site") that
/// morphs into a 48px round plus button via iOS-style fade+scale when
/// the search query is not in the visible list. Null label + no plus
/// hides it.
class _ActionFab extends StatelessWidget {
  const _ActionFab({this.label, this.plus = false, this.onTap});

  final String? label;
  final bool plus;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final visible = plus || label != null;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: AnimatedScale(
          scale: visible ? 1.0 : 0.6,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutBack,
          child: PressableScale(
            onTap: visible ? onTap : null,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.7, end: 1.0).animate(animation),
                  child: child,
                ),
              ),
              child: plus
                  ? _FabShell(
                      key: const ValueKey('plus'),
                      width: 48,
                      child: AppIcon(AppIconName.add, size: 22, color: AppColors.bg),
                    )
                  : _FabShell(
                      key: ValueKey('label-$label'),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIcon(AppIconName.add, size: 16, color: AppColors.bg),
                          const SizedBox(width: 8),
                          Text(label ?? '',
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.bg)),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FabShell extends StatelessWidget {
  const _FabShell({super.key, this.width, this.padding, required this.child});

  final double? width;
  final EdgeInsetsGeometry? padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 48,
      padding: padding,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          AppIconView(packageName: packageName),
          const SizedBox(width: 12),
          Expanded(
            child: Text(appName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppText.body, color: AppColors.ink)),
          ),
          Text('Internet blocked',
              style: TextStyle(fontSize: 11, color: AppColors.inkDim)),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () async {
              await ref.read(databaseProvider).setInternetBlocked(packageName, false);
              ref.read(enforcementSyncProvider).push();
            },
            child: AppIcon(AppIconName.close, size: 15, color: AppColors.inkFaint),
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
  const _SiteTile({required this.rule});
  final WebsiteRule rule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
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
                fontSize: 13,
                color: rule.enabled ? AppColors.ink : AppColors.inkFaint,
              ),
            ),
          ),
          Switch(
            value: rule.enabled,
            onChanged: (v) {
              ref.read(databaseProvider).setRuleEnabled(rule.id, v);
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
            child: GestureDetector(
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
    final template = view.template;

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

    return Column(
      children: [
        // Category enable toggle — for one-way categories this is the
        // "lock" moment, confirmed by an irreversible dialog.
        Switch(
          value: view.enabled,
          onChanged: view.locked
              ? null // locked: cannot be disabled anymore
              : (v) => _setEnabled(context, ref, v),
        ),
        GestureDetector(
          onTap: () => _openSites(context, ref),
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('View sites',
                style: TextStyle(fontSize: 10, color: AppColors.inkFaint)),
          ),
        ),
        if (!view.locked && template.id != 'adult')
          GestureDetector(
            onTap: () async {
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
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Remove list',
                  style: TextStyle(fontSize: 10, color: AppColors.inkFaint)),
            ),
          ),
      ],
    );
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
              child: TextField(
                onChanged: (v) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 250), () {
                    setState(() => _query = v);
                  });
                },
                style: TextStyle(color: AppColors.ink, fontSize: 13.5),
                decoration: InputDecoration(
                  hintText: 'Search ${widget.view.template.title.toLowerCase()} sites…',
                  hintStyle: TextStyle(color: AppColors.inkFaint, fontSize: 12.5),
                  prefixIcon: Padding(
                    padding: const EdgeInsets.all(12),
                    child: AppIcon(AppIconName.search, size: 16, color: AppColors.inkFaint),
                  ),
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
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
                    itemBuilder: (context, i) => _SiteTile(rule: rows[i]),
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
