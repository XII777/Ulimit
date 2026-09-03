import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/icons/app_icons.dart';
import '../../core/native/permissions_channel.dart';
import '../../core/theme/premium_components.dart';
import '../../shared/widgets/app_sheet.dart';
import '../../core/theme/tokens.dart';
import '../../data/apps_repository.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../shared/widgets/app_selector.dart';
import '../../shared/widgets/duration_flow.dart';
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
                    AppIcon(AppIconName.block, size: 18, color: AppColors.bg),
                    const SizedBox(width: 10),
                    Text('Block an application',
                        style: TextStyle(
                            fontSize: AppText.body, fontWeight: FontWeight.w600, color: AppColors.bg)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            Text('ACTIVE',
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
                  return  _EmptyState();
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
                  style: TextStyle(fontSize: 12, color: AppColors.inkFaint)),
            ),

            const SizedBox(height: 24),
            Text('ENDED',
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
          duration: permanent ? null : expiresAt.difference(DateTime.now()),
          permanent: permanent,
          invincible: invincible,
        );

    if (context.mounted) {
      showAppSnack(context, permanent ? '$appName blocked until manually removed' : '$appName blocked');
    }
  }

  Future<bool?> _confirmPermanent(BuildContext context, String appName) {
    return showAppConfirmSheet(
      context,
      title: 'Block $appName permanently?',
      message: 'The app stays blocked until you remove the block here. '
          'There is no automatic end — this is not a temporary block.',
      confirmLabel: 'Block permanently',
    );
  }
}

class _EmptyState extends StatelessWidget {
   _EmptyState();

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
      child: Column(
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

    // "Until HH:MM" was replaced by a live rolling countdown (see the
    // FlowDurationText row below); permanent blocks keep the static
    // label inline.

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
                    style: TextStyle(fontSize: 14, color: AppColors.ink)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (restriction.invincible) ...[
                      AppIcon(AppIconName.lock, size: 10, color: AppColors.inkDim),
                      const SizedBox(width: 4),
                    ],
                    if (restriction.permanent)
                      Flexible(
                        child: Text('Until manually removed',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: AppColors.inkDim)),
                      )
                    else
                      Flexible(
                        child: FlowDurationText(
                          _remainingUntil(restriction.expiresAt!),
                          suffix: ' left',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.ink),
                          suffixStyle:
                              TextStyle(fontSize: 11, color: AppColors.inkDim),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _remove(context, ref),
            icon: AppIcon(AppIconName.close, size: 16, color: AppColors.inkFaint),
          ),
        ],
      ),
    );
  }

  /// Live remaining time until this restriction expires, clamped so a
  /// just-passed expiry never renders as negative.
  Duration _remainingUntil(DateTime expiresAt) {
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) return Duration.zero;
    // Coarse display: sub-minute blocks read as one minute, same as the
    // old formatter's clamp(1, 59).
    if (remaining < const Duration(minutes: 1)) return const Duration(minutes: 1);
    return remaining;
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
                  style: TextStyle(fontSize: 12.5, color: AppColors.inkDim)),
            ),
            Text(
              restriction.enabled ? 'Ended' : 'Removed',
              style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint),
            ),
          ],
        ),
      ),
    );
  }
}
