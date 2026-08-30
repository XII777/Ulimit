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

/// Internet & Sites: local VPN status, per-app internet blocking,
/// custom domain rules, and the downloadable HaGeZi block-list
/// categories with per-site toggles.
class InternetSitesScreen extends ConsumerStatefulWidget {
  const InternetSitesScreen({super.key});

  @override
  ConsumerState<InternetSitesScreen> createState() => _InternetSitesScreenState();
}

class _InternetSitesScreenState extends ConsumerState<InternetSitesScreen>
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
    // VPN state can change while backgrounded; refresh on resume.
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(vpnStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          physics: springScrollPhysics,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            PremiumHeader(
              title: 'Internet & Sites',
              subtitle: 'Local, on-device filtering — no remote proxy',
            ),
            const SizedBox(height: 18),

            _VpnCard(),
            const SizedBox(height: 20),

            const Text('APP INTERNET ACCESS',
                style: TextStyle(
                    fontSize: AppText.overline,
                    color: AppColors.inkFaint,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            _InternetBlocksSection(),
            const SizedBox(height: 20),

            const Text('BLOCKED WEBSITES',
                style: TextStyle(
                    fontSize: AppText.overline,
                    color: AppColors.inkFaint,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            const _CustomSitesSection(),
            const SizedBox(height: 20),

            const Text('BLOCK LISTS',
                style: TextStyle(
                    fontSize: AppText.overline,
                    color: AppColors.inkFaint,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                'Curated domain lists by category. Download a list, toggle '
                'individual sites on or off. Blocked domains resolve to '
                'nothing while the local VPN is active.',
                style: TextStyle(fontSize: 11.5, color: AppColors.inkFaint, height: 1.5),
              ),
            ),
            const _BlockListSection(),
          ],
        ),
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
    final settings = ref.watch(ulimitSettingsProvider).valueOrNull;
    final running = status.valueOrNull?.running ?? false;

    return PremiumCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(running ? 'Network protection active' : 'Network protection inactive',
                        style: const TextStyle(
                            fontSize: AppText.title, fontWeight: FontWeight.w600, color: AppColors.ink)),
                    Text(
                      running
                          ? 'Internet blocks and website filters are enforced'
                          : 'Turn on to enforce internet & website rules',
                      style: const TextStyle(fontSize: AppText.caption, color: AppColors.inkDim),
                    ),
                  ],
                ),
              ),
              Switch(
                value: running,
                onChanged: (v) async {
                  if (v) {
                    final ok = await EnforcementChannel.startVpn();
                    if (ok) {
                      await ref.read(settingsControllerProvider).setVpnEnabled(true);
                    }
                    // reflect the requested state even if the user must
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
          if ((settings?.vpnEnabled ?? false) && !running) ...[
            const SizedBox(height: 10),
            const Text(
              'Ulimit will reconnect the VPN automatically after a restart.',
              style: TextStyle(fontSize: 11, color: AppColors.inkFaint),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Per-app internet blocks
// ---------------------------------------------------------------------------

class _InternetBlocksSection extends ConsumerWidget {
  const _InternetBlocksSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks = ref.watch(internetBlocksProvider);
    final catalog = ref.watch(appsCatalogProvider);

    return blocks.when(
      data: (rows) => Column(
        children: [
          for (final row in rows) ...[
            _InternetBlockRow(
              packageName: row.packageName,
              appName: catalog.valueOrNull?.nameFor(row.packageName) ?? row.packageName,
            ),
            const SizedBox(height: 8),
          ],
          PressableScale(
            onTap: () async {
              final pkg = await showAppSelector(context, title: 'Block internet for');
              if (pkg == null) return;
              await ref.read(databaseProvider).setInternetBlocked(pkg, true);
              ref.read(enforcementSyncProvider).push();
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.stroke),
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppIcon(AppIconName.add, size: 15, color: AppColors.inkDim),
                  const SizedBox(width: 8),
                  Text('Add app',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.inkDim)),
                ],
              ),
            ),
          ),
        ],
      ),
      loading: () => const SizedBox(
          height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
      error: (e, _) => Text('Could not load: $e',
          style: const TextStyle(fontSize: 12, color: AppColors.inkFaint)),
    );
  }
}

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
                style: const TextStyle(fontSize: AppText.body, color: AppColors.ink)),
          ),
          const Text('Internet blocked',
              style: TextStyle(fontSize: 11, color: AppColors.inkDim)),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () async {
              await ref.read(databaseProvider).setInternetBlocked(packageName, false);
              ref.read(enforcementSyncProvider).push();
            },
            child: const AppIcon(AppIconName.close, size: 15, color: AppColors.inkFaint),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Custom sites
// ---------------------------------------------------------------------------

class _CustomSitesSection extends ConsumerStatefulWidget {
  const _CustomSitesSection();

  @override
  ConsumerState<_CustomSitesSection> createState() => _CustomSitesSectionState();
}

class _CustomSitesSectionState extends ConsumerState<_CustomSitesSection> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(customWebsiteRulesProvider);

    return rules.when(
      data: (rows) => Column(
        children: [
          if (rows.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: AppColors.stroke),
              ),
              child: const Text(
                'No custom sites yet.\nAdd any domain — every site you add gets its own toggle.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.inkFaint, height: 1.5),
              ),
            )
          else
            for (final rule in rows)
              _SiteTile(rule: rule),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  style: const TextStyle(color: AppColors.ink, fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: 'Add a website, e.g. example.com',
                    hintStyle: const TextStyle(color: AppColors.inkFaint, fontSize: 12.5),
                    filled: true,
                    fillColor: AppColors.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              PressableScale(
                onTap: _addDomain,
                child: Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: AppColors.ink,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: const AppIcon(AppIconName.add, size: 18, color: AppColors.bg),
                ),
              ),
            ],
          ),
        ],
      ),
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Text('Could not load sites: $e',
          style: const TextStyle(fontSize: 12, color: AppColors.inkFaint)),
    );
  }

  Future<void> _addDomain() async {
    final db = ref.read(databaseProvider);
    final ok = await db.addCustomDomain(_controller.text);
    _controller.clear();
    if (!ok && mounted) {
      showAppSnack(context, 'Enter a valid domain, e.g. example.com');
    }
    ref.read(enforcementSyncProvider).push();
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
          const AppIcon(AppIconName.link, size: 13, color: AppColors.inkFaint),
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
            activeColor: AppColors.bg,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Block lists
// ---------------------------------------------------------------------------

class _BlockListSection extends ConsumerWidget {
  const _BlockListSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(blockListCategoriesProvider);

    return categories.when(
      data: (list) => Column(
        children: [
          for (final view in list) ...[
            _BlockListTile(view: view),
            const SizedBox(height: 6),
          ],
        ],
      ),
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Text('Could not load lists: $e',
          style: const TextStyle(fontSize: 12, color: AppColors.inkFaint)),
    );
  }
}

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
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.ink)),
                      ),
                      if (template.recommended) ...[
                        const SizedBox(width: 6),
                        const Text('RECOMMENDED',
                            style: TextStyle(fontSize: 8.5, letterSpacing: 0.5, color: AppColors.inkFaint)),
                      ],
                      if (view.locked) ...[
                        const SizedBox(width: 6),
                        const AppIcon(AppIconName.lock, size: 11, color: AppColors.inkDim),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    template.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: AppColors.inkFaint, height: 1.4),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    view.downloaded
                        ? '${view.siteCount} sites · downloaded '
                            '${_fmtDate(view.downloadedAt)}${view.enabled ? '' : ' · filter off'}'
                        : '~${_fmtCount(template.approxEntries)} sites · not downloaded',
                    style: const TextStyle(fontSize: 10.5, color: AppColors.inkFaint),
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
          child: const Text('Download',
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
          child: const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('View sites',
                style: TextStyle(fontSize: 10, color: AppColors.inkFaint)),
          ),
        ),
        if (!view.locked && template.id != 'adult')
          GestureDetector(
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  backgroundColor: AppColors.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
                  title: Text('Remove "${template.title}"?',
                      style: const TextStyle(fontSize: 15, color: AppColors.ink)),
                  content: Text('All ${template.title} sites and their toggles will be deleted.',
                      style: TextStyle(fontSize: 12.5, color: AppColors.inkDim)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(false),
                        child: const Text('Cancel', style: TextStyle(color: AppColors.inkDim))),
                    TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        child: const Text('Remove', style: TextStyle(color: AppColors.ink))),
                  ],
                ),
              );
              if (confirmed == true) {
                await ref.read(blockListRepositoryProvider).removeCategory(template.id);
                ref.read(enforcementSyncProvider).push();
              }
            },
          child: const Padding(
            padding: EdgeInsets.only(top: 4),
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
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
          title: const Text('This cannot be undone',
              style: TextStyle(fontSize: 16, color: AppColors.ink)),
          content: const Text(
            'Once adult-content blocking is turned on, it cannot be turned '
            'off again. The list will keep blocking adult sites on this '
            'device. Individual sites inside the list can still be '
            'toggled, but the filter itself stays on permanently.',
            style: TextStyle(fontSize: 12.5, color: AppColors.inkDim, height: 1.55),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel', style: TextStyle(color: AppColors.inkDim)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Turn on permanently',
                  style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
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
                      icon: const AppIcon(AppIconName.back, size: 15, color: AppColors.inkDim),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.view.template.title,
                            style: const TextStyle(
                                fontSize: AppText.headline, fontWeight: FontWeight.w600, color: AppColors.ink)),
                        Text('${widget.view.siteCount} sites',
                            style: const TextStyle(fontSize: AppText.caption, color: AppColors.inkDim)),
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
                style: const TextStyle(color: AppColors.ink, fontSize: 13.5),
                decoration: InputDecoration(
                  hintText: 'Search ${widget.view.template.title.toLowerCase()} sites…',
                  hintStyle: const TextStyle(color: AppColors.inkFaint, fontSize: 12.5),
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
                    return const Center(
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
                      style: const TextStyle(fontSize: 12, color: AppColors.inkFaint)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
