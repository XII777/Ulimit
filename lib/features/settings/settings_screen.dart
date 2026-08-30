import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crash/crash_collector.dart';
import '../../core/icons/app_icons.dart';
import '../../core/native/permissions_channel.dart';
import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/db/app_database.dart';
import '../../data/permissions_providers.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../shared/widgets/app_sheet.dart';
import '../../shared/widgets/spring_scroll.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(allPermissionsProvider);
    final settings = ref.watch(ulimitSettingsProvider).valueOrNull;
    final budget = ref.watch(dailyBudgetProvider).valueOrNull ?? 240;

    // Top spacing is owned by NavShell's collapsing inset.
    return ListView(
      physics: springScrollPhysics,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 110),
      children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          const Text('Local profile · not synced',
              style: TextStyle(fontSize: AppText.body, color: AppColors.inkDim)),
          const SizedBox(height: 20),

          const PremiumSectionLabel('GENERAL'),
          const SizedBox(height: 8),
          PremiumCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                PremiumListTile(
                  label: 'Daily screen-time budget',
                  sublabel: 'Drives the Home ring — $budget min / day',
                  trailing: const AppIcon(AppIconName.edit, size: 15, color: AppColors.inkFaint),
                  onTap: () => _editBudget(context, ref, budget),
                ),
                const PremiumDivider(),
                PremiumListTile(
                  label: 'Default focus duration',
                  sublabel: '${settings?.defaultFocusMinutes ?? 25} minutes',
                  trailing: const AppIcon(AppIconName.chevronRight, size: 14, color: AppColors.inkFaint),
                  onTap: () => _editDefaultFocus(context, ref, settings?.defaultFocusMinutes ?? 25),
                ),
                const PremiumDivider(),
                PremiumListTile(
                  label: 'Haptics',
                  sublabel: 'Tactile feedback on key actions',
                  trailing: Switch(
                    value: settings?.hapticsEnabled ?? true,
                    onChanged: (v) => ref.read(settingsControllerProvider).setHapticsEnabled(v),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          const PremiumSectionLabel('PERMISSIONS'),
          const SizedBox(height: 8),
          PremiumCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final p in permissions) ...[
                  _PermissionRow(
                    label: _labelFor(p.kind),
                    granted: p.granted,
                    loading: p.loading,
                  ),
                  if (p != permissions.last) const PremiumDivider(),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),

          const PremiumSectionLabel('DATA'),
          const SizedBox(height: 8),
          PremiumCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                PremiumListTile(
                  label: 'Export data',
                  sublabel: 'Save limits, rules & history as JSON to your device',
                  trailing: const AppIcon(AppIconName.export, size: 15, color: AppColors.inkFaint),
                  onTap: () => _exportData(context, ref),
                ),
                const PremiumDivider(),
                PremiumListTile(
                  label: 'Import data',
                  sublabel: 'Restore an Ulimit export file',
                  trailing: const AppIcon(AppIconName.import, size: 15, color: AppColors.inkFaint),
                  onTap: () => _importData(context, ref),
                ),
                const PremiumDivider(),
                PremiumListTile(
                  label: 'Crash logs',
                  sublabel: 'Review, copy or export captured crash reports',
                  trailing: const AppIcon(AppIconName.info, size: 15, color: AppColors.inkFaint),
                  onTap: () => _showCrashLogs(context),
                ),
                const PremiumDivider(),
                PremiumListTile(
                  label: 'Delete all data',
                  sublabel: 'Usage, focus history, rules and lists — permanent',
                  onTap: () => _deleteAllData(context, ref),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          const PremiumSectionLabel('ABOUT'),
          const SizedBox(height: 8),
          PremiumCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                PremiumListTile(
                  label: 'Privacy',
                  sublabel: 'All data stays on this device. No account, no cloud, no ads.',
                  trailing: const AppIcon(AppIconName.info, size: 15, color: AppColors.inkFaint),
                ),
                const PremiumDivider(),
                const PremiumListTile(
                  label: 'Block-list source',
                  sublabel: 'HaGeZi dns-blocklists (GPL-3.0), downloaded on demand',
                ),
                const PremiumDivider(),
                const PremiumListTile(label: 'Version', sublabel: '0.2.0'),
              ],
            ),
          ),
        ],
      );
  }

  String _labelFor(PermissionKind kind) => switch (kind) {
        PermissionKind.accessibility => 'Accessibility',
        PermissionKind.vpn => 'VPN & network',
        PermissionKind.deviceAdmin => 'Device admin',
        PermissionKind.notificationListener => 'Notification access',
        PermissionKind.biometric => 'Biometrics',
      };

  Future<void> _editBudget(BuildContext context, WidgetRef ref, int current) async {
    final db = ref.read(databaseProvider);
    final controller = TextEditingController(text: '$current');
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        title: const Text('Daily budget (minutes)', style: TextStyle(fontSize: 15.5, color: AppColors.ink)),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: AppColors.ink),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel', style: TextStyle(color: AppColors.inkDim))),
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(int.tryParse(controller.text)),
              child: const Text('Save', style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (value != null && value > 0) {
      await setDailyBudget(db, value);
    }
  }

  Future<void> _editDefaultFocus(BuildContext context, WidgetRef ref, int current) async {
    const options = [15, 25, 45, 60, 90];
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        title: const Text('Default focus duration', style: TextStyle(fontSize: 15.5, color: AppColors.ink)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in options)
              ListTile(
                title: Text('$m minutes', style: const TextStyle(color: AppColors.ink, fontSize: 14)),
                trailing: m == current ? const AppIcon(AppIconName.check, size: 15) : null,
                onTap: () => Navigator.of(dialogContext).pop(m),
              ),
          ],
        ),
      ),
    );
    if (value != null) {
      await ref.read(settingsControllerProvider).setDefaultFocusMinutes(value);
    }
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        title: const Text('Delete all data?', style: TextStyle(fontSize: 15.5, color: AppColors.ink)),
        content: const Text(
          'Usage history, focus sessions, limits, restrictions, groups, '
          'bedtime settings, websites and downloaded lists will be '
          'permanently removed from this device.',
          style: TextStyle(fontSize: 12.5, color: AppColors.inkDim, height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel', style: TextStyle(color: AppColors.inkDim))),
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete everything',
                  style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600))),
        ],
      ),
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
        child: const Text('Clear all', style: TextStyle(fontSize: 12.5, color: AppColors.inkDim)),
      ),
      builder: (_, scrollController) =>
          _CrashLogsContent(scrollController: scrollController, revision: revision),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.label, required this.granted, required this.loading});
  final String label;
  final bool granted;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.ink))),
          if (loading)
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(
                  granted ? AppIconName.check : AppIconName.close,
                  size: 13,
                  color: granted ? AppColors.ink : AppColors.inkFaint,
                ),
                const SizedBox(width: 6),
                Text(
                  granted ? 'Granted' : 'Pending',
                  style: TextStyle(
                      fontSize: 10.5,
                      color: granted ? AppColors.ink : AppColors.inkDim,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
        ],
      ),
    );
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
                const AppIcon(AppIconName.check, size: 22, color: AppColors.inkFaint),
                const SizedBox(height: 10),
                const Text('No crashes captured',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.ink)),
                const SizedBox(height: 4),
                const Text(
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
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: files.length,
          separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.stroke),
          itemBuilder: (context, i) {
            final file = files[i] as File;
            final stat = file.statSync();
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text(
                _prettyName(file.uri.pathSegments.last),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, color: AppColors.ink),
              ),
              subtitle: Text(
                '${_formatDate(stat.modified)} · ${_formatSize(stat.size)}',
                style: const TextStyle(fontSize: 11, color: AppColors.inkFaint),
              ),
              trailing: const AppIcon(AppIconName.chevronRight, size: 13, color: AppColors.inkFaint),
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
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        title: Text(_prettyName(file.uri.pathSegments.last),
            style: const TextStyle(fontSize: 14, color: AppColors.ink)),
        content: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: SingleChildScrollView(
            physics: springScrollPhysics,
            child: SelectableText(
              content,
              style: const TextStyle(fontSize: 10.5, color: AppColors.inkDim, height: 1.45),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: content));
              showAppSnack(dialogContext, 'Copied to clipboard');
            },
            child: const Text('Copy', style: TextStyle(color: AppColors.ink)),
          ),
          TextButton(
            onPressed: () async {
              await NativePermissions.exportFile(content);
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            },
            child: const Text('Save to Downloads',
                style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600)),
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
