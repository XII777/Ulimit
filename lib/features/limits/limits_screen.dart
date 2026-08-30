import 'package:drift/drift.dart' show InsertMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/restriction_engine.dart';
import '../../core/icons/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../data/apps_repository.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../shared/widgets/app_selector.dart';
import '../../shared/widgets/pressable_scale.dart';
import '../../shared/widgets/spring_scroll.dart';

/// Daily limits — per-app allowances and shared-pool restriction
/// groups. Usage shown here is the exact input the enforcement engine
/// consumes, so a bar that reads "under limit" can never be blocked.
class LimitsScreen extends ConsumerWidget {
  const LimitsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLimits = ref.watch(appLimitsProvider);
    final groups = ref.watch(restrictionGroupsProvider);

    return ListView(
      physics: springScrollPhysics,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 110),
      children: [
        Text('Limits', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        const Text('Daily allowances that reset at midnight',
            style: TextStyle(fontSize: AppText.body, color: AppColors.inkDim)),
        const SizedBox(height: 20),

        const Text('APP LIMITS',
            style: TextStyle(
                fontSize: AppText.overline, color: AppColors.inkFaint, letterSpacing: 0.6, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        appLimits.when(
          data: (limits) => limits.isEmpty
              ? const _EmptyHint(text: 'No app limits yet.\nPick an app and set a daily allowance.')
              : Column(
                  children: [
                    for (final limit in limits) ...[
                      _AppLimitRow(view: limit),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
          loading: () => const SizedBox(
              height: 80, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
          error: (e, _) => _EmptyHint(text: 'Could not load limits: $e'),
        ),
        const SizedBox(height: 8),
        _AddTile(
          icon: AppIconName.add,
          label: 'Add app limit',
          onTap: () => _addAppLimit(context, ref),
        ),

        const SizedBox(height: 28),
        const Text('RESTRICTION GROUPS',
            style: TextStyle(
                fontSize: AppText.overline, color: AppColors.inkFaint, letterSpacing: 0.6, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        groups.when(
          data: (data) {
            final totalApps = data.fold<int>(0, (sum, g) => sum + g.packageNames.length);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (data.isEmpty)
                  const _EmptyHint(
                      text: 'No groups yet.\nGroup apps that share one combined allowance —\n'
                          'a per-app limit is easy to circumvent, a pool is not.')
                else ...[
                  for (final g in data) ...[
                    _GroupCard(group: g),
                    const SizedBox(height: 8),
                  ],
                  Padding(
                    padding: const EdgeInsets.only(left: 2, top: 2),
                    child: Text('${data.length} groups · $totalApps apps covered',
                        style: const TextStyle(fontSize: 11, color: AppColors.inkFaint)),
                  ),
                ],
              ],
            );
          },
          loading: () => const SizedBox(
              height: 80, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
          error: (e, _) => _EmptyHint(text: 'Could not load groups: $e'),
        ),
        const SizedBox(height: 8),
        _AddTile(
          icon: AppIconName.add,
          label: 'New restriction group',
          onTap: () => _createGroup(context, ref),
        ),
      ],
    );
  }

  Future<void> _addAppLimit(BuildContext context, WidgetRef ref) async {
    final pkg = await showAppSelector(context, title: 'Set a daily limit');
    if (pkg == null || !context.mounted) return;
    final catalog = ref.read(appsCatalogProvider).valueOrNull;
    await _showLimitEditor(context, ref, packageName: pkg, appName: catalog?.nameFor(pkg) ?? pkg);
  }

  Future<void> _showLimitEditor(
    BuildContext context,
    WidgetRef ref, {
    required String packageName,
    required String appName,
    int initialSeconds = 30 * 60,
  }) async {
    final result = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
      builder: (_) => _LimitEditorSheet(appName: appName, initialSeconds: initialSeconds),
    );
    if (result == null || result <= 0) return;
    await ref.read(databaseProvider).setAppLimit(packageName, Duration(seconds: result));
  }

  Future<void> _createGroup(BuildContext context, WidgetRef ref) async {
    final db = ref.read(databaseProvider);

    final name = await _promptGroupName(context);
    if (name == null || name.trim().isEmpty || !context.mounted) return;

    final apps = await showAppSelector(context, title: 'Add apps to "$name"', multiSelect: true);
    if (apps is! Set<String> || apps.isEmpty || !context.mounted) return;

    final minutes = await _promptGroupLimit(context);
    if (minutes == null || !context.mounted) return;

    final id = await db.into(db.restrictionGroups).insert(
          RestrictionGroupsCompanion.insert(
            name: name.trim(),
            dailyLimitSeconds: minutes * 60,
          ),
        );
    for (final p in apps) {
      await db.into(db.restrictionGroupApps).insert(
            RestrictionGroupAppsCompanion.insert(groupId: id, packageName: p),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Text(text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12.5, color: AppColors.inkFaint, height: 1.5)),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.icon, required this.label, required this.onTap});
  final AppIconName icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.stroke),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(icon, size: 16, color: AppColors.inkDim),
            const SizedBox(width: 8),
            Text(label,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.inkDim)),
          ],
        ),
      ),
    );
  }
}

class _AppLimitRow extends ConsumerWidget {
  const _AppLimitRow({required this.view});
  final AppLimitView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(appsCatalogProvider);
    final appName = catalog.valueOrNull?.nameFor(view.packageName) ?? view.packageName;
    final ratio = ratioOf(used: view.usedSeconds, limit: view.limitSeconds);
    final over = view.usedSeconds >= view.limitSeconds;

    return PressableScale(
      onTap: () => _edit(context, ref),
      child: Container(
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
                AppIconView(packageName: view.packageName),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.ink)),
                ),
                Text(
                  over
                      ? 'Limit reached'
                      : '${formatDurationShort(Duration(seconds: view.remainingSeconds))} left',
                  style: TextStyle(fontSize: 11, color: over ? AppColors.ink : AppColors.inkDim),
                ),
                const SizedBox(width: 6),
                const AppIcon(AppIconName.chevronRight, size: 13, color: AppColors.inkFaint),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: ratio),
                      duration: const Duration(milliseconds: 500),
                      builder: (_, value, __) => LinearProgressIndicator(
                        value: value,
                        minHeight: 5,
                        backgroundColor: AppColors.stroke,
                        valueColor: AlwaysStoppedAnimation(
                            over || ratio >= 0.75 ? AppColors.ink : AppColors.inkDim),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${formatDurationShort(Duration(seconds: view.usedSeconds))} / '
                  '${formatDurationShort(Duration(seconds: view.limitSeconds))}',
                  style: const TextStyle(fontSize: 10.5, color: AppColors.inkFaint),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final catalog = ref.read(appsCatalogProvider).valueOrNull;
    final appName = catalog?.nameFor(view.packageName) ?? view.packageName;

    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text('Edit limit — $appName',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.ink)),
            ),
            ListTile(
              title: const Text('Change daily limit', style: TextStyle(color: AppColors.ink, fontSize: 14)),
              onTap: () => Navigator.of(sheetContext).pop('change'),
            ),
            ListTile(
              title: const Text('Remove limit', style: TextStyle(color: AppColors.ink, fontSize: 14)),
              onTap: () => Navigator.of(sheetContext).pop('remove'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (result == null) return;
    final db = ref.read(databaseProvider);
    if (result == 'remove') {
      await db.removeAppLimit(view.packageName);
      return;
    }
    if (context.mounted) {
      final seconds = await showModalBottomSheet<int>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.bg,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
        builder: (_) => _LimitEditorSheet(appName: appName, initialSeconds: view.limitSeconds),
      );
      if (seconds != null && seconds > 0) {
        await db.setAppLimit(view.packageName, Duration(seconds: seconds));
      }
    }
  }
}

class _LimitEditorSheet extends StatefulWidget {
  const _LimitEditorSheet({required this.appName, required this.initialSeconds});
  final String appName;
  final int initialSeconds;

  @override
  State<_LimitEditorSheet> createState() => _LimitEditorSheetState();
}

class _LimitEditorSheetState extends State<_LimitEditorSheet> {
  late double _minutes = widget.initialSeconds / 60.0;

  static const _presets = [15, 30, 45, 60, 90, 120, 180];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Daily limit — ${widget.appName}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.ink)),
            const SizedBox(height: 18),
            Text(
              formatDurationShort(Duration(minutes: _minutes.round())),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600, color: AppColors.ink),
            ),
            Slider(
              value: _minutes.clamp(5, 360),
              min: 5,
              max: 360,
              divisions: 71,
              onChanged: (v) => setState(() => _minutes = v),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final m in _presets)
                  GestureDetector(
                    onTap: () => setState(() => _minutes = m.toDouble()),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: _minutes.round() == m ? AppColors.ink : AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        '${m}m',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _minutes.round() == m ? AppColors.bg : AppColors.inkDim),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            TextButton(
              onPressed: () => Navigator.of(context).pop(_minutes.round() * 60),
              style: TextButton.styleFrom(
                backgroundColor: AppColors.ink,
                foregroundColor: AppColors.bg,
                padding: const EdgeInsets.all(14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
              ),
              child: const Text('Save limit', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group});
  final RestrictionGroupView group;

  @override
  Widget build(BuildContext context) {
    final hasLimit = group.limitSeconds > 0;
    final ratio = hasLimit ? ratioOf(used: group.usedSeconds, limit: group.limitSeconds) : 0.0;
    final over = group.usedSeconds >= group.limitSeconds;

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
              Expanded(
                child: Text(group.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.ink)),
              ),
              Text(
                hasLimit
                    ? '${formatDurationShort(Duration(seconds: group.usedSeconds))} / '
                        '${formatDurationShort(Duration(seconds: group.limitSeconds))}'
                    : 'No limit',
                style: const TextStyle(fontSize: 11, color: AppColors.inkDim),
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
                  valueColor: AlwaysStoppedAnimation(
                      over || ratio >= 0.75 ? AppColors.ink : AppColors.inkDim),
                ),
              ),
            ),
          ],
          if (group.invincible) ...[
            const SizedBox(height: 8),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(AppIconName.lock, size: 11, color: AppColors.inkDim),
                SizedBox(width: 4),
                Text('Protected', style: TextStyle(fontSize: 10, color: AppColors.inkDim)),
              ],
            ),
          ],
        ],
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
      return const Text('No apps assigned',
          style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint));
    }
    final shown = packageNames.take(6).toList();
    return Row(
      children: [
        for (final pkg in shown) ...[
          AppIconView(packageName: pkg, size: 22),
          const SizedBox(width: 6),
        ],
        if (packageNames.length > shown.length)
          Text('+${packageNames.length - shown.length}',
              style: const TextStyle(fontSize: 10, color: AppColors.inkFaint)),
      ],
    );
  }
}

Future<String?> _promptGroupName(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      title: const Text('Group name', style: TextStyle(fontSize: 16, color: AppColors.ink)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: const TextStyle(color: AppColors.ink),
        decoration: const InputDecoration(
          hintText: 'e.g. Social Media',
          hintStyle: TextStyle(color: AppColors.inkFaint),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel', style: TextStyle(color: AppColors.inkDim)),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: const Text('Next', style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
}

Future<int?> _promptGroupLimit(BuildContext context) {
  const presets = [15, 30, 60, 90, 120];
  return showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      title: const Text('Combined daily limit', style: TextStyle(fontSize: 16, color: AppColors.ink)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in presets)
            ListTile(
              title: Text('$m minutes', style: const TextStyle(color: AppColors.ink, fontSize: 14)),
              onTap: () => Navigator.of(dialogContext).pop(m),
            ),
        ],
      ),
    ),
  );
}
