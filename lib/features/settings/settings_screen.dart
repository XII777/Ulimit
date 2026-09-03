import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/crash/crash_collector.dart';
import '../../core/constants/build_info.dart';
import '../../core/icons/app_icons.dart';
import '../../core/native/enforcement_channel.dart';
import '../../core/native/permissions_channel.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/db/app_database.dart';
import '../../data/focus_indicator.dart';
import '../../data/focus_tags_provider.dart';
import '../../data/permissions_providers.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../shared/widgets/app_sheet.dart';
import '../../shared/widgets/pressable_scale.dart';
import '../../shared/widgets/spring_scroll.dart';
import '../../shared/widgets/session_tag_editor.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  // Single-open accordion: the one expanded section, or null when all
  // are collapsed (the default at the start of every visit). Tapping an
  // open section collapses it; tapping another swaps to that one.
  String? _expanded;

  // Last known route path; leaving the settings route (tab switch,
  // pushed detail screen) collapses everything again, so each visit to
  // Settings starts fully collapsed.
  String? _lastLocation;

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
    // Android gives no callback for "user returned from Settings" — the
    // only reliable signal is resuming, so re-check every permission
    // then (the Allow/Block sheet sends users into system screens).
    if (state == AppLifecycleState.resumed) {
      ref.read(permissionsRefreshTickProvider.notifier).state++;
    }
  }

  void _toggle(String section) => setState(() {
        _expanded = _expanded == section ? null : section;
      });

  @override
  Widget build(BuildContext context) {
    // Depends on the router state registry → this screen rebuilds on
    // every route change (the same scope NavShell watches), even while
    // its tab page is kept alive.
    final location = GoRouterState.of(context).uri.path;
    if (location != _lastLocation) {
      _lastLocation = location;
      if (location != Routes.settings) _expanded = null;
    }

    final permissions = ref.watch(allPermissionsProvider);
    final settings = ref.watch(ulimitSettingsProvider).valueOrNull;
    final themeMode = ref.watch(themeModeProvider).valueOrNull ?? 'system';
    final focusIndicatorEnabled =
        ref.watch(focusIndicatorEnabledProvider).valueOrNull ?? true;

    // Top spacing is owned by NavShell's collapsing inset.
    return ListView(
      physics: springScrollPhysics,
      padding: EdgeInsets.fromLTRB(
          20, 16, 20,
          ref.watch(hideNavBarProvider).valueOrNull == true ? navBarHiddenInset : navBarPillInset),
      children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Local profile · not synced',
              style: TextStyle(fontSize: AppText.body, color: AppColors.inkDim)),
          const SizedBox(height: 20),

           CollapsibleSection(
            label: 'GENERAL',
            icon: AppIconName.settings,
            expanded: _expanded == 'GENERAL',
            onToggle: () => _toggle('GENERAL'),
            child: PremiumCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                PremiumListTile(
                  label: 'Tile Appearance',
                  sublabel: _appearanceLabel(themeMode),
                  trailing: AppIcon(AppIconName.chevronRight, size: 14, color: AppColors.inkFaint),
                  onTap: () => _pickAppearance(context, ref),
                ),
                PremiumListTile(
                  label: 'Session Tags',
                  sublabel: _sessionTagsLabel(context, ref),
                  trailing: AppIcon(AppIconName.chevronRight, size: 14, color: AppColors.inkFaint),
                  onTap: () => _manageSessionTags(context, ref),
                ),
                PremiumListTile(
                  label: 'Haptics',
                  sublabel: 'Tactile feedback on key actions',
                  trailing: Switch(
                    value: settings?.hapticsEnabled ?? true,
                    onChanged: (v) => ref.read(settingsControllerProvider).setHapticsEnabled(v),
                  ),
                ),
                PremiumListTile(
                  label: 'Hide Nav Bar',
                  sublabel: 'Immersive browsing — remove the bottom nav pill',
                  trailing: Switch(
                    value: settings?.hideNavBar ?? false,
                    onChanged: (v) => ref.read(settingsControllerProvider).setHideNavBar(v),
                  ),
                ),
              ],
            ),
          ),
          ),
          const SizedBox(height: 20),

           CollapsibleSection(
            label: 'FOCUS',
            icon: AppIconName.focus,
            expanded: _expanded == 'FOCUS',
            onToggle: () => _toggle('FOCUS'),
            child: PremiumCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
               PremiumListTile(
                 label: 'Focus Session Indicator',
                 sublabel: 'Show your active Focus Session in the Android system area',
                 trailing: Switch(
                   value: focusIndicatorEnabled,
                   onChanged: (v) async {
                     await ref.read(settingsControllerProvider).setFocusIndicatorEnabled(v);
                     await ref.read(focusIndicatorSyncProvider).sync();
                   },
                 ),
               ),
              ],
            ),
          ),
          ),
          const SizedBox(height: 20),

          // Permissions: one tile that opens the full sheet — why each
          // permission is needed, plus Allow/Block actions that open
          // the right system screen so they can change any time.
          Text('PERMISSIONS',
              style: TextStyle(
                  fontSize: AppText.overline,
                  color: AppColors.inkFaint,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          PremiumCard(
            padding: EdgeInsets.zero,
            child: PremiumListTile(
              label: 'App permissions',
              sublabel: _permissionsSummary(permissions),
              trailing: AppIcon(AppIconName.chevronRight, size: 14, color: AppColors.inkFaint),
              onTap: () => _showPermissionsSheet(context),
            ),
          ),
          const SizedBox(height: 20),

           CollapsibleSection(
            label: 'DATA',
            icon: AppIconName.chart,
            expanded: _expanded == 'DATA',
            onToggle: () => _toggle('DATA'),
            child: PremiumCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                PremiumListTile(
                  label: 'Export data',
                  sublabel: 'Save limits, rules & history as JSON to your device',
                  trailing: AppIcon(AppIconName.export, size: 15, color: AppColors.inkFaint),
                  onTap: () => _exportData(context, ref),
                ),
                PremiumListTile(
                  label: 'Import data',
                  sublabel: 'Restore an Ulimit export file',
                  trailing: AppIcon(AppIconName.import, size: 15, color: AppColors.inkFaint),
                  onTap: () => _importData(context, ref),
                ),
                PremiumListTile(
                  label: 'Crash logs',
                  sublabel: 'Review, copy or export captured crash reports',
                  trailing: AppIcon(AppIconName.info, size: 15, color: AppColors.inkFaint),
                  onTap: () => _showCrashLogs(context),
                ),
                PremiumListTile(
                  label: 'Blocking diagnostics',
                  sublabel: 'Live status of the enforcement engine',
                  trailing: AppIcon(AppIconName.info, size: 15, color: AppColors.inkFaint),
                  onTap: () => _showBlockDiagnostics(context),
                ),
                PremiumListTile(
                  label: 'Delete all data',
                  sublabel: 'Usage, focus history, rules and lists — permanent',
                  onTap: () => _deleteAllData(context, ref),
                ),
              ],
            ),
          ),
          ),
          const SizedBox(height: 20),

           CollapsibleSection(
            label: 'ABOUT',
            icon: AppIconName.info,
            expanded: _expanded == 'ABOUT',
            onToggle: () => _toggle('ABOUT'),
            child: PremiumCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                PremiumListTile(
                  label: 'Privacy',
                  sublabel: 'All data stays on this device. No account, no cloud, no ads.',
                  trailing: AppIcon(AppIconName.info, size: 15, color: AppColors.inkFaint),
                ),
                 PremiumListTile(
                  label: 'Block-list source',
                  sublabel: 'StevenBlack/hosts (MIT), downloaded on demand',
                ),
                 PremiumListTile(label: 'Version', sublabel: '0.2.0'),
              ],
            ),
          ),
          ),
        ],
      );
  }

  String _permissionsSummary(List<PermissionStatus> permissions) {
    final granted = permissions.where((p) => p.granted).length;
    return '$granted of ${permissions.length} granted · allow or revoke anytime';
  }

  /// The permission sheet: for every permission, what it does (why
  /// Ulimit needs it), its current state, and an Allow/Block action so
  /// the user can change it whenever they want. Allow runs the request
  /// flow (system dialog or the matching settings page); Block opens
  /// the same system screen — or for device admin, revokes in-app —
  /// where the grant can be turned off.
  Future<void> _showPermissionsSheet(BuildContext context) async {
    await showAppSheet<void>(
      context: context,
      title: 'Permissions',
      subtitle: 'Why each one is needed — allow or block at any time',
      initialSize: 0.85,
      minSize: 0.4,
      builder: (_, scrollController) => ListView(
        controller: scrollController,
        physics: springScrollPhysics,
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          for (final p in ref.watch(allPermissionsProvider))
            _PermissionSheetRow(status: p),
        ],
      ),
    );
  }

  String _appearanceLabel(String mode) => switch (mode) {
        'dark' => 'AMOLED dark',
        'white' => 'White',
        _ => 'System',
      };

  Future<void> _pickAppearance(BuildContext context, WidgetRef ref) async {
    final themeMode = ref.read(themeModeProvider).valueOrNull ?? 'system';
    final selected = await showAppSheet<String>(
      context: context,
      title: 'Tile Appearance',
      builder: (sheetContext, scrollController) => ListView(
        controller: scrollController,
        physics: springScrollPhysics,
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          for (final (mode, label, sub) in [
            ('system', 'System', 'Follow the Android appearance'),
            ('dark', 'Dark', 'AMOLED pure-black theme'),
            ('white', 'White', 'Monochrome white theme'),
          ])
            ListTile(
              title: Text(label, style: TextStyle(color: AppColors.ink, fontSize: 14)),
              subtitle: Text(sub, style: TextStyle(fontSize: 11, color: AppColors.inkFaint)),
              trailing: mode == themeMode ? AppIcon(AppIconName.check, size: 15) : null,
              onTap: () => Navigator.of(sheetContext).pop(mode),
            ),
        ],
      ),
    );
    if (selected != null && selected != themeMode) {
      await ref.read(settingsControllerProvider).setThemeMode(selected);
    }
  }

  // ---------------------------------------------------------------------
  // Session tags (Appearance)
  // ---------------------------------------------------------------------

  String _sessionTagsLabel(BuildContext context, WidgetRef ref) {
    final count = ref.watch(focusTagsProvider).valueOrNull?.length ?? 0;
    final colored = ref.watch(coloredSessionTagsProvider).valueOrNull ?? false;
    if (count == 0) return 'Create tags for focus sessions';
    return '$count tag${count == 1 ? '' : 's'} · ${colored ? 'colored' : 'monochrome'}';
  }

  Future<void> _manageSessionTags(BuildContext context, WidgetRef ref) async {
    final colored = ref.watch(coloredSessionTagsProvider).valueOrNull ?? false;

    await showAppSheet<void>(
      context: context,
      title: 'Session Tags',
      subtitle: 'Manage the tags shown on the Focus screen',
      trailing: Switch(
        value: colored,
        onChanged: (v) =>
            ref.read(settingsControllerProvider).setColoredSessionTags(v),
      ),
      builder: (sheetContext, scrollController) => _SessionTagsManager(
        controller: ref.read(focusTagsControllerProvider),
        scrollController: scrollController,
      ),
    );
  }

  Future<void> _exportData(BuildContext context, WidgetRef ref) async {
    final db = ref.read(databaseProvider);
    final json = await buildExport(db);
    final path = await NativePermissions.exportFile(json);
    if (!context.mounted) return;
    showAppSnack(context, path == null ? 'Export failed' : 'Exported to Downloads');
  }

  Future<void> _importData(BuildContext context, WidgetRef ref) async {
    final db = ref.read(databaseProvider);
    final json = await NativePermissions.importFile();
    if (json == null || !context.mounted) return;
    final ok = await restoreExport(db, json);
    if (!context.mounted) return;
    showAppSnack(context, ok ? 'Data restored' : 'Import failed — not a valid Ulimit export');
  }

  Future<void> _deleteAllData(BuildContext context, WidgetRef ref) async {
    final confirmed = await showAppConfirmSheet(
      context,
      title: 'Delete all data?',
      message: 'Usage history, focus sessions, limits, restrictions, groups, '
          'bedtime settings, websites and downloaded lists will be '
          'permanently removed from this device.',
      confirmLabel: 'Delete everything',
    );
    if (confirmed == true) {
      await ref.read(databaseProvider).wipeAllData();
    }
  }

  Future<void> _showCrashLogs(BuildContext context) async {
    final revision = ValueNotifier<int>(0);
    await showAppSheet<void>(
      context: context,
      title: 'Crash logs',
      subtitle: 'Captured on-device. Never uploaded — copy or export a log '
          'only when reporting a problem.',
      initialSize: 0.85,
      minSize: 0.4,
      trailing: TextButton(
        onPressed: () {
          CrashCollector.clear();
          revision.value++;
        },
        child: Text('Clear all', style: TextStyle(fontSize: 12.5, color: AppColors.inkDim)),
      ),
      builder: (_, scrollController) =>
          _CrashLogsContent(scrollController: scrollController, revision: revision),
    );
  }

  Future<void> _showBlockDiagnostics(BuildContext context) async {
    await showAppSheet<void>(
      context: context,
      title: 'Blocking diagnostics',
      subtitle: 'Live state of the enforcement chain: Dart policy → '
          'native snapshot → engine. Reproduce a block, then reopen.',
      initialSize: 0.8,
      minSize: 0.35,
      builder: (_, scrollController) => FutureBuilder<String>(
        future: _blockDiagnosticsText(),
        builder: (context, snapshot) {
          final text = snapshot.data;
          if (text == null) {
            return const Center(child: CircularProgressIndicator(strokeWidth: 2));
          }
          return ListView(
            controller: scrollController,
            physics: springScrollPhysics,
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: SelectableText(
                  text,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.55,
                    fontFamily: 'monospace',
                    color: AppColors.ink,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Chain: a restriction row (DART) must appear in a push '
                '(SYNC) and in native blockedNow (NATIVE). The first '
                'broken stage is the failing layer.',
                style: TextStyle(fontSize: 11.5, color: AppColors.inkFaint, height: 1.5),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<String> _blockDiagnosticsText() async {
    final db = ref.read(databaseProvider);
    final manual = await db.select(db.appRestrictions).get();
    final now = DateTime.now();
    final activeRows = manual
        .where((r) =>
            r.enabled && (r.permanent || (r.expiresAt?.isAfter(now) ?? false)))
        .toList();
    final decisions = ref.read(restrictionDecisionsProvider);
    final blockedDecisions = decisions.entries
        .where((e) => e.value.appBlocked)
        .map((e) => '${e.key} (${e.value.reason?.label ?? "Blocked"})')
        .toList();
    final native = await EnforcementChannel.enforcementStatus();

    final sb = StringBuffer();
    sb.writeln('build: $buildLabel');
    sb.writeln('now: $now');
    sb.writeln('--- DART ---');
    sb.writeln('db rows (all): ${manual.length}');
    for (final r in manual.take(8)) {
      sb.writeln(
          '  #${r.id} ${r.packageName} enabled=${r.enabled} '
          'permanent=${r.permanent} expires=${r.expiresAt}');
    }
    sb.writeln('db rows (active): ${activeRows.length}');
    sb.writeln('engine decisions (blocked): ${blockedDecisions.length}');
    for (final d in blockedDecisions.take(8)) {
      sb.writeln('  $d');
    }
    sb.writeln('--- SYNC ---');
    sb.writeln(EnforcementSync.lastPushSummary);
    if (EnforcementSync.lastPushError != null) {
      sb.writeln('error: ${EnforcementSync.lastPushError}');
    }
    sb.writeln('--- NATIVE ---');
    sb.write(native);
    return sb.toString();
  }
}

/// Why each permission exists — the "why we need it" copy shown in the
/// permissions sheet, matched to the onboarding cards.
const Map<PermissionKind, (String, String)> _permissionWhy = {
  PermissionKind.accessibility: (
    'The core engine',
    'Detects app usage, enforces limits, and shows the block screen instantly. '
        'Android only lets you toggle this in system Settings.',
  ),
  PermissionKind.vpn: (
    'Local network filter',
    'Creates a local, on-device filter that powers internet and website blocking. '
        'Nothing is routed through any server.',
  ),
  PermissionKind.deviceAdmin: (
    'Tamper protection',
    'Stops Ulimit from being uninstalled or force-stopped to bypass a limit. '
        'Can also be revoked right here, in one tap.',
  ),
  PermissionKind.notificationListener: (
    'Focus quiet mode',
    'Lets Ulimit batch or mute notifications while a focus session runs.',
  ),
  PermissionKind.biometric: (
    'Device capability',
    'Protects your limits with your fingerprint or face. Availability depends '
        'on this device — there is nothing to allow or block.',
  ),
  PermissionKind.usageAccess: (
    'Exact screen time',
    'Reads the per-app usage times from the system (the same source Digital '
        'Wellbeing uses) for accurate dashboard charts.',
  ),
  PermissionKind.overlayPermission: (
    'Block screen anywhere',
    'Lets the standalone blocking service draw the block screen itself when '
        'accessibility is off.',
  ),
};

class _PermissionSheetRow extends ConsumerWidget {
  const _PermissionSheetRow({required this.status});

  final PermissionStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final why = _permissionWhy[status.kind]!;
    final granted = status.granted;
    final togglable = status.kind != PermissionKind.biometric;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _settingsLabel(status.kind),
                  style: TextStyle(
                      fontSize: AppText.body, fontWeight: FontWeight.w600, color: AppColors.ink),
                ),
              ),
              if (status.loading)
                const SizedBox(
                    width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: granted ? AppColors.ink : AppColors.surface2,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: granted ? null : Border.all(color: AppColors.stroke),
                  ),
                  child: Text(
                    granted ? 'Granted' : 'Blocked',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: granted ? AppColors.bg : AppColors.inkDim,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(why.$1, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.inkDim)),
          const SizedBox(height: 2),
          Text(why.$2, style: TextStyle(fontSize: 11.5, height: 1.45, color: AppColors.inkFaint)),
          if (togglable) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (!granted)
                  Expanded(
                    child: TextButton(
                      onPressed: () => _act(context, ref, allow: true),
                      style: TextButton.styleFrom(
                        backgroundColor: AppColors.ink,
                        foregroundColor: AppColors.bg,
                        padding: const EdgeInsets.all(12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md)),
                      ),
                      child: const Text('Allow',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  )
                else
                  Expanded(
                    child: TextButton(
                      onPressed: () => _act(context, ref, allow: false),
                      style: TextButton.styleFrom(
                        backgroundColor: AppColors.surface2,
                        foregroundColor: AppColors.inkDim,
                        side: BorderSide(color: AppColors.stroke),
                        padding: const EdgeInsets.all(12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md)),
                      ),
                      child: const Text('Block'),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _settingsLabel(PermissionKind kind) => switch (kind) {
        PermissionKind.accessibility => 'Accessibility',
        PermissionKind.vpn => 'VPN & network',
        PermissionKind.deviceAdmin => 'Device admin',
        PermissionKind.notificationListener => 'Notification access',
        PermissionKind.biometric => 'Biometrics',
        PermissionKind.usageAccess => 'Usage access',
        PermissionKind.overlayPermission => 'Display over apps',
      };

  /// Allow: trigger the grant flow (system dialog where supported,
  /// otherwise the matching system Settings page). Block: hand the user
  /// the screen where the grant can be revoked — device admin is
  /// deactivated in-app directly.
  Future<void> _act(BuildContext context, WidgetRef ref, {required bool allow}) async {
    switch (status.kind) {
      case PermissionKind.accessibility:
        await NativePermissions.openAccessibilitySettings();
      case PermissionKind.notificationListener:
        await NativePermissions.openNotificationListenerSettings();
      case PermissionKind.vpn:
        if (allow) {
          await NativePermissions.requestVpnPermission();
        } else {
          await NativePermissions.openVpnSettings();
        }
      case PermissionKind.deviceAdmin:
        if (allow) {
          await NativePermissions.requestDeviceAdmin();
          ref.read(deviceAdminAcknowledgedProvider.notifier).state = true;
        } else {
          await NativePermissions.deactivateDeviceAdmin();
          ref.read(deviceAdminAcknowledgedProvider.notifier).state = false;
        }
      case PermissionKind.biometric:
        return;
      case PermissionKind.usageAccess:
        await NativePermissions.openUsageAccessSettings();
      case PermissionKind.overlayPermission:
        await NativePermissions.openOverlaySettings();
    }
    // The in-app dialogs resolve synchronously enough for an immediate
    // re-check; system Settings pages refresh on lifecycle resume via
    // the screen's observer.
    ref.read(permissionsRefreshTickProvider.notifier).state++;
  }
}

// ---------------------------------------------------------------------------
// Export / restore
// ---------------------------------------------------------------------------

/// Builds a JSON document of the user's configuration and history.
/// Downloaded block-list domains are deliberately excluded: they are
/// re-downloadable public data, and a 100k-row blob would make the
/// export enormous for no benefit.
Future<String> buildExport(AppDatabase db) async {
  final limits = await db.select(db.appLimits).get();
  final restrictions = await db.select(db.appRestrictions).get();
  final groups = await db.select(db.restrictionGroups).get();
  final groupApps = await db.select(db.restrictionGroupApps).get();
  final internet = await db.select(db.internetBlocks).get();
  final bedtime = await db.select(db.bedtimeSchedule).get();
  final customSites = await (db.select(db.websiteRules)..where((t) => t.category.equals('custom'))).get();
  final settings = await db.select(db.ulimitSettings).get();
  final profile = await db.select(db.profile).get();
  final focus = await db.select(db.focusSessions).get();

  return const JsonEncoder.withIndent('  ').convert({
    'app': 'ulimit',
    'schemaVersion': 2,
    'exportedAt': DateTime.now().toIso8601String(),
    'tables': {
      'profile': [for (final r in profile) _rowJson(r.toJson())],
      'ulimit_settings': [for (final r in settings) _rowJson(r.toJson())],
      'app_limits': [for (final r in limits) _rowJson(r.toJson())],
      'app_restrictions': [for (final r in restrictions) _rowJson(r.toJson())],
      'restriction_groups': [for (final r in groups) _rowJson(r.toJson())],
      'restriction_group_apps': [for (final r in groupApps) _rowJson(r.toJson())],
      'internet_blocks': [for (final r in internet) _rowJson(r.toJson())],
      'bedtime_schedule': [for (final r in bedtime) _rowJson(r.toJson())],
      'website_rules_custom': [for (final r in customSites) _rowJson(r.toJson())],
      'focus_sessions': [for (final r in focus) _rowJson(r.toJson())],
    },
  });
}

dynamic _rowJson(Map<String, dynamic> row) {
  return row.map((k, v) {
    if (v is DateTime) return MapEntry(k, v.toIso8601String());
    return MapEntry(k, v);
  });
}

/// Restores an export produced by [buildExport]. Wipes the affected
/// tables first so the result matches the file exactly. Returns false
/// for malformed input without touching anything.
Future<bool> restoreExport(AppDatabase db, String jsonString) async {
  final dynamic doc;
  try {
    doc = const JsonDecoder().convert(jsonString);
  } on FormatException {
    return false;
  }
  if (doc is! Map || doc['app'] != 'ulimit') return false;
  final tablesJson = doc['tables'];
  if (tablesJson is! Map) return false;

  dynamic read(String table) => tablesJson[table];

  return db.transaction(() async {
    await (db.delete(db.appLimits)).go();
    await (db.delete(db.appRestrictions)).go();
    await (db.delete(db.restrictionGroups)).go();
    await (db.delete(db.restrictionGroupApps)).go();
    await (db.delete(db.internetBlocks)).go();
    await (db.delete(db.bedtimeSchedule)).go();
    await (db.delete(db.websiteRules)).go();
    await (db.delete(db.focusSessions)).go();

    // Drift's generated toJson() uses Dart field names (camelCase);
    // restore reads exactly what buildExport wrote.
    for (final row in (read('app_limits') as List? ?? [])) {
      await db.into(db.appLimits).insert(AppLimitsCompanion.insert(
            packageName: row['packageName'] as String,
            dailyLimitSeconds: row['dailyLimitSeconds'] as int,
          ));
    }
    for (final row in (read('app_restrictions') as List? ?? [])) {
      await db.into(db.appRestrictions).insert(AppRestrictionsCompanion.insert(
            packageName: row['packageName'] as String,
            createdAt: DateTime.parse(row['createdAt'] as String),
            expiresAt: Value(row['expiresAt'] == null
                ? null
                : DateTime.parse(row['expiresAt'] as String)),
            permanent: Value(row['permanent'] as bool? ?? false),
            invincible: Value(row['invincible'] as bool? ?? false),
          ));
    }
    for (final row in (read('restriction_groups') as List? ?? [])) {
      await db.into(db.restrictionGroups).insert(RestrictionGroupsCompanion.insert(
            name: row['name'] as String,
            dailyLimitSeconds: row['dailyLimitSeconds'] as int,
            invincible: Value(row['invincible'] as bool? ?? false),
          ));
    }
    for (final row in (read('restriction_group_apps') as List? ?? [])) {
      await db.into(db.restrictionGroupApps).insert(RestrictionGroupAppsCompanion.insert(
            groupId: row['groupId'] as int,
            packageName: row['packageName'] as String,
          ));
    }
    for (final row in (read('internet_blocks') as List? ?? [])) {
      await db.setInternetBlocked(row['packageName'] as String, true);
    }
    for (final row in (read('bedtime_schedule') as List? ?? [])) {
      final id = await db.into(db.bedtimeSchedule).insert(BedtimeScheduleCompanion.insert(
            startTime: row['startTime'] as String,
            endTime: row['endTime'] as String,
          ));
      await (db.update(db.bedtimeSchedule)..where((t) => t.id.equals(id))).write(
        BedtimeScheduleCompanion(
          enabled: Value(row['enabled'] as bool? ?? false),
          dndEnabled: Value(row['dndEnabled'] as bool? ?? true),
          pauseApps: Value(row['pauseApps'] as bool? ?? true),
          blockInternet: Value(row['blockInternet'] as bool? ?? false),
          grayscale: Value(row['grayscale'] as bool? ?? false),
        ),
      );
    }
    for (final row in (read('website_rules_custom') as List? ?? [])) {
      await db.into(db.websiteRules).insert(WebsiteRulesCompanion.insert(
            domain: row['domain'] as String,
            category: const Value('custom'),
            enabled: Value(row['enabled'] as bool? ?? true),
          ));
    }
    for (final row in (read('focus_sessions') as List? ?? [])) {
      await db.into(db.focusSessions).insert(FocusSessionsCompanion.insert(
            label: row['label'] as String,
            startedAt: DateTime.parse(row['startedAt'] as String),
            plannedSeconds: row['plannedSeconds'] as int,
            endedAt: Value(row['endedAt'] == null ? null : DateTime.parse(row['endedAt'] as String)),
            invincible: Value(row['invincible'] as bool? ?? false),
            completed: Value(row['completed'] as bool? ?? false),
          ));
    }
    return true;
  });
}

// ---------------------------------------------------------------------------
// Crash logs viewer
// ---------------------------------------------------------------------------

class _CrashLogsContent extends StatefulWidget {
  const _CrashLogsContent({required this.scrollController, required this.revision});
  final ScrollController scrollController;
  final ValueNotifier<int> revision;

  @override
  State<_CrashLogsContent> createState() => _CrashLogsContentState();
}

class _CrashLogsContentState extends State<_CrashLogsContent> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.revision,
      builder: (context, revision, __) {
        return FutureBuilder<List<FileSystemEntity>>(
          key: ValueKey(revision),
          future: CrashCollector.list(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final files = snapshot.data ?? const [];
        if (files.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(AppIconName.check, size: 22, color: AppColors.inkFaint),
                const SizedBox(height: 10),
                Text('No crashes captured',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.ink)),
                const SizedBox(height: 4),
                Text(
                  'When the app hits an error, the report\nappears here automatically.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: AppColors.inkFaint, height: 1.5),
                ),
              ],
            ),
          );
        }
        return ListView.separated(
          controller: widget.scrollController,
          physics: springScrollPhysics,
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: files.length,
          separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.stroke),
          itemBuilder: (context, i) {
            final file = files[i] as File;
            final stat = file.statSync();
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text(
                _prettyName(file.uri.pathSegments.last),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, color: AppColors.ink),
              ),
              subtitle: Text(
                '${_formatDate(stat.modified)} · ${_formatSize(stat.size)}',
                style: TextStyle(fontSize: 11, color: AppColors.inkFaint),
              ),
              trailing: AppIcon(AppIconName.chevronRight, size: 13, color: AppColors.inkFaint),
              onTap: () => _viewLog(context, file),
            );
          },
        );
      },
        );
      },
    );
  }

  Future<void> _viewLog(BuildContext context, File file) async {
    final content = await file.readAsString();
    if (!context.mounted) return;
    await showAppSheet<void>(
      context: context,
      title: _prettyName(file.uri.pathSegments.last),
      initialSize: 0.85,
      minSize: 0.4,
      builder: (sheetContext, scrollController) => Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              physics: springScrollPhysics,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: SelectableText(
                content,
                style: TextStyle(fontSize: 10.5, color: AppColors.inkDim, height: 1.45),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: content));
                      showAppSnack(sheetContext, 'Copied to clipboard');
                    },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.all(14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md)),
                    ),
                    child: Text('Copy', style: TextStyle(color: AppColors.ink)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextButton(
                    onPressed: () async {
                      await NativePermissions.exportFile(content);
                      if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                    },
                    style: TextButton.styleFrom(
                      backgroundColor: AppColors.ink,
                      foregroundColor: AppColors.bg,
                      padding: const EdgeInsets.all(14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md)),
                    ),
                    child: Text('Save to Downloads',
                        style: TextStyle(color: AppColors.bg, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _prettyName(String raw) {
    // "flutter-2026-08-30T06-12-00.123.log" → "Flutter crash · 30 Aug, 06:12"
    final kind = raw.startsWith('native-')
        ? 'Native crash'
        : raw.startsWith('flutter-')
            ? 'Flutter crash'
            : raw.startsWith('async-')
                ? 'Async error'
                : raw.startsWith('isolate-')
                    ? 'Isolate error'
                    : 'Crash';
    final match = RegExp(r'(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})').firstMatch(raw);
    if (match == null) return kind;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final day = match.group(3) ?? '';
    final monthIndex = (int.tryParse(match.group(2) ?? '1') ?? 1).clamp(1, 12);
    final time = '${match.group(4) ?? ''}:${match.group(5) ?? ''}';
    return '$kind · $day ${months[monthIndex - 1]}, $time';
  }

  String _formatDate(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${dt.day} ${months[dt.month - 1]}, '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
}

/// In-sheet tag manager used from Settings → Session Tags. Lists every
/// tag with its color dot (honoring the colored toggle), plus a New
/// button. Tapping a row opens the shared tag editor (rename, recolor,
/// delete) — the same editor the Focus screen's hold-to-edit opens.
class _SessionTagsManager extends ConsumerWidget {
  const _SessionTagsManager({
    required this.controller,
    required this.scrollController,
  });

  final FocusTagsController controller;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(focusTagsProvider).valueOrNull ?? const <FocusTag>[];

    return ListView(
      controller: scrollController,
      physics: springScrollPhysics,
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        PressableScale(
          onTap: () => _create(context),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 13),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: AppColors.stroke),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(AppIconName.add, size: 14, color: AppColors.inkDim),
                const SizedBox(width: 8),
                Text('New tag',
                    style: TextStyle(
                        fontSize: AppText.body, fontWeight: FontWeight.w600, color: AppColors.ink)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (tags.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'No session tags yet. Create one to label your focus sessions.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: AppColors.inkFaint),
            ),
          )
        else
          for (final tag in tags)
            GestureDetector(
              onTap: () => _edit(context, tag),
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: AppColors.stroke),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: Color(tag.colorValue),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(tag.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: AppText.body, color: AppColors.ink)),
                    ),
                    AppIcon(AppIconName.edit, size: 13, color: AppColors.inkFaint),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _create(BuildContext context) async {
    await showTagEditor(
      context,
      onSave: (name, color) =>
          controller.createTag(name: name, color: color),
    );
  }

  Future<void> _edit(BuildContext context, FocusTag tag) async {
    await showTagEditor(
      context,
      tagId: tag.id,
      initialName: tag.name,
      initialColor: Color(tag.colorValue),
      onSave: (name, color) async {
        await controller.renameTag(tag.id, name);
        await controller.recolorTag(tag.id, color);
      },
      onDelete: () => controller.deleteTag(tag.id),
    );
  }
}
