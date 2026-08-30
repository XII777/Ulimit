import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/restriction_engine.dart';
import '../../core/icons/app_icons.dart';
import '../../core/native/permissions_channel.dart';
import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/apps_repository.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../shared/widgets/app_selector.dart';
import '../../shared/widgets/pressable_scale.dart';
import '../../shared/widgets/spring_scroll.dart';

/// Manual app blocking: temporary blocks with explicit expiry,
/// persistent blocks, and the Invincible-Mode-protected variant.
class RestrictionsScreen extends ConsumerWidget {
  const RestrictionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restrictions = ref.watch(manualRestrictionsProvider);
    final catalog = ref.watch(appsCatalogProvider);
    final settings = ref.watch(ulimitSettingsProvider).valueOrNull;

    final now = DateTime.now();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          physics: springScrollPhysics,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            PremiumHeader(
              title: 'App Blocking',
              subtitle: 'Temporary & persistent blocks',
            ),
            const SizedBox(height: 18),

            PressableScale(
              onTap: () => _startBlockFlow(context, ref),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.ink,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AppIcon(AppIconName.block, size: 18, color: AppColors.bg),
                    const SizedBox(width: 10),
                    Text('Block an application',
                        style: TextStyle(
                            fontSize: AppText.body, fontWeight: FontWeight.w600, color: AppColors.bg)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            const Text('ACTIVE',
                style: TextStyle(
                    fontSize: AppText.overline,
                    color: AppColors.inkFaint,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            restrictions.when(
              data: (rows) {
                final active = rows
                    .where((r) => r.enabled && (r.permanent || (r.expiresAt?.isAfter(now) ?? false)))
                    .toList();
                if (active.isEmpty) {
                  return const _EmptyState();
                }
                return Column(
                  children: [
                    for (final r in active) ...[
                      _ActiveRestrictionRow(
                        restriction: r,
                        appName: catalog.valueOrNull?.nameFor(r.packageName) ?? r.packageName,
                        protectedByBiometric: settings?.biometricProtection ?? false,
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                );
              },
              loading: () => const SizedBox(
                  height: 100, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
              error: (e, _) => Text('Could not load restrictions: $e',
                  style: const TextStyle(fontSize: 12, color: AppColors.inkFaint)),
            ),

            const SizedBox(height: 24),
            const Text('ENDED',
                style: TextStyle(
                    fontSize: AppText.overline,
                    color: AppColors.inkFaint,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            restrictions.when(
              data: (rows) {
                final ended = rows
                    .where((r) => !r.enabled || (!r.permanent && r.expiresAt != null && !r.expiresAt!.isAfter(now)))
                    .toList();
                if (ended.isEmpty) {
                  return const SizedBox.shrink();
                }
                return Column(
                  children: [
                    for (final r in ended.take(10))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _EndedRow(
                          restriction: r,
                          appName: catalog.valueOrNull?.nameFor(r.packageName) ?? r.packageName,
                        ),
                      ),
                  ],
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startBlockFlow(BuildContext context, WidgetRef ref) async {
    final pkg = await showAppSelector(context, title: 'Block an application');
    if (pkg == null || !context.mounted) return;

    final catalog = ref.read(appsCatalogProvider).valueOrNull;
    final appName = catalog?.nameFor(pkg) ?? pkg;

    final expiresAt = await showDurationSelector(context, appName);
    if (expiresAt == null && !context.mounted) return;
    // showDurationSelector returns null both for "permanent" and for
    // dismiss — resolve permanent explicitly via a confirm dialog.
    final permanent = expiresAt == null;

    if (permanent) {
      final confirmed = await _confirmPermanent(context, appName);
      if (confirmed != true || !context.mounted) return;
    }

    final settings = ref.read(ulimitSettingsProvider).valueOrNull;
    var invincible = false;
    if (settings?.biometricProtection ?? false) {
      invincible = await NativePermissions.authenticate(
        reason: 'Protect this restriction with biometric authentication?',
      );
    }

    await ref.read(databaseProvider).blockApp(
          packageName: pkg,
          duration: permanent ? null : expiresAt?.difference(DateTime.now()),
          permanent: permanent,
          invincible: invincible,
        );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.surface2,
          behavior: SnackBarBehavior.floating,
          content: Text(
            permanent ? '$appName blocked until manually removed' : '$appName blocked',
            style: const TextStyle(color: AppColors.ink, fontSize: 12.5),
          ),
        ),
      );
    }
  }

  Future<bool?> _confirmPermanent(BuildContext context, String appName) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        title: Text('Block $appName permanently?',
            style: const TextStyle(fontSize: 15.5, color: AppColors.ink)),
        content: const Text(
          'The app stays blocked until you remove the block here. '
          'There is no automatic end — this is not a temporary block.',
          style: TextStyle(fontSize: 12.5, color: AppColors.inkDim, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel', style: TextStyle(color: AppColors.inkDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Block permanently',
                style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: const Column(
        children: [
          AppIcon(AppIconName.block, size: 20, color: AppColors.inkFaint),
          SizedBox(height: 10),
          Text('No active restrictions',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.ink)),
          SizedBox(height: 4),
          Text(
            'Applications you restrict will appear here.\n'
            'Blocks end automatically at their expiry time.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.inkFaint, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _ActiveRestrictionRow extends ConsumerWidget {
  const _ActiveRestrictionRow({
    required this.restriction,
    required this.appName,
    required this.protectedByBiometric,
  });

  final AppRestriction restriction;
  final String appName;
  final bool protectedByBiometric;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(evaluationTickProvider);

    final until = restriction.permanent
        ? 'Until manually removed'
        : 'Until ${_formatExpiry(restriction.expiresAt!)}';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          AppIconView(packageName: restriction.packageName),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(appName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, color: AppColors.ink)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (restriction.invincible) ...[
                      const AppIcon(AppIconName.lock, size: 10, color: AppColors.inkDim),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(until,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: AppColors.inkDim)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _remove(context, ref),
            icon: const AppIcon(AppIconName.close, size: 16, color: AppColors.inkFaint),
          ),
        ],
      ),
    );
  }

  String _formatExpiry(DateTime expiresAt) {
    final now = DateTime.now();
    final remaining = expiresAt.difference(now);
    if (remaining.inHours >= 24) {
      return '${remaining.inDays + 1}d from now';
    }
    if (remaining.inHours >= 1) {
      return '${remaining.inHours}h ${remaining.inMinutes % 60}m';
    }
    return '${remaining.inMinutes.clamp(1, 59)}m';
  }
  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    if (restriction.invincible || protectedByBiometric) {
      final ok = await NativePermissions.authenticate(
        reason: 'Removing this protected restriction requires authentication.',
      );
      if (!ok) return;
    }
    await ref.read(databaseProvider).removeRestriction(restriction.id);
  }
}

class _EndedRow extends StatelessWidget {
  const _EndedRow({required this.restriction, required this.appName});
  final AppRestriction restriction;
  final String appName;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.55,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            AppIconView(packageName: restriction.packageName, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(appName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.inkDim)),
            ),
            Text(
              restriction.enabled ? 'Ended' : 'Removed',
              style: const TextStyle(fontSize: 10.5, color: AppColors.inkFaint),
            ),
          ],
        ),
      ),
    );
  }
}
