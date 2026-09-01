import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/icons/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/native/permissions_channel.dart';
import '../../data/permissions_providers.dart';

/// Compact "permissions were reset" screen for users who have already
/// completed onboarding once.
///
/// Android re-claims accessibility / notification-listener access after
/// EVERY app update (by design — privileged access must be re-approved
/// by the user on package updates). The full onboarding wizard is the
/// wrong response to that: the user didn't change their mind, their
/// data is all still here, and the *only* thing missing is the system
/// grant the update churned. This screen says exactly that and offers
/// one-tap re-enable for just the missing permissions.
class PermissionsRecoveryScreen extends ConsumerStatefulWidget {
  const PermissionsRecoveryScreen({super.key, required this.onReEnabled});

  /// Called once every required permission is re-granted. The caller's
  /// provider watch normally handles the transition — this is a backstop
  /// for platforms/edges where the watch doesn't fire.
  final VoidCallback onReEnabled;

  @override
  ConsumerState<PermissionsRecoveryScreen> createState() => _PermissionsRecoveryScreenState();
}

class _PermissionsRecoveryScreenState extends ConsumerState<PermissionsRecoveryScreen>
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
    // Android gives no callback for "user returned from Settings" — the
    // standard pattern is to re-check permissions on resume.
    if (state == AppLifecycleState.resumed) {
      ref.read(permissionsRefreshTickProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(allPermissionsProvider);

    const notRequired = {
      PermissionKind.biometric,
      PermissionKind.deviceAdmin,
      PermissionKind.usageAccess,
    };
    final missing = permissions
        .where((p) => !notRequired.contains(p.kind) && !p.granted)
        .toList();
    final allReEnabled = missing.isEmpty;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.stroke),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        AppIcon(AppIconName.info, size: 16, color: AppColors.inkDim),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Ulimit updated — access was reset',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: AppColors.ink,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Android re-asks for system access after every app update — that\'s '
                      'a security feature, not a change to your data or settings. '
                      'Everything is exactly as you left it. Tap to re-enable below.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: missing.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppIcon(AppIconName.check, size: 22, color: AppColors.inkFaint),
                            const SizedBox(height: 10),
                            Text(
                              'All access restored',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.ink),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: missing.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) =>
                            _RecoveryCard(status: missing[i]),
                      ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      allReEnabled ? widget.onReEnabled : (_allReEnabledNoop()),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.ink,
                    disabledBackgroundColor: AppColors.surface2,
                    padding: const EdgeInsets.all(15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: Text(
                    allReEnabled ? 'Continue' : 'Re-enable to continue',
                    style: TextStyle(
                      color: allReEnabled ? AppColors.bg : AppColors.inkFaint,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  VoidCallback? _allReEnabledNoop() {
    // When something is still missing, the button just refreshes the
    // permission state (in case the user toggled a grant that a
    // lifecycle re-check hasn't picked up) and otherwise stays idle.
    return () => ref.read(permissionsRefreshTickProvider.notifier).state++;
  }
}

class _RecoveryCard extends ConsumerWidget {
  const _RecoveryCard({required this.status});
  final PermissionStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = _label(status.kind);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meta.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13.5),
                ),
                const SizedBox(height: 2),
                Text(meta.description, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: status.loading ? null : () => _reEnable(ref),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(
                'Open',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.bg,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reEnable(WidgetRef ref) async {
    switch (status.kind) {
      case PermissionKind.accessibility:
        await NativePermissions.openAccessibilitySettings();
      case PermissionKind.notificationListener:
        await NativePermissions.openNotificationListenerSettings();
      case PermissionKind.vpn:
        await NativePermissions.requestVpnPermission();
      case PermissionKind.usageAccess:
        await NativePermissions.openUsageAccessSettings();
      default:
        return;
    }
    ref.read(permissionsRefreshTickProvider.notifier).state++;
  }
}

class _RecoveryLabel {
  const _RecoveryLabel(this.title, this.description);
  final String title;
  final String description;
}

_RecoveryLabel _label(PermissionKind kind) {
  switch (kind) {
    case PermissionKind.accessibility:
      return const _RecoveryLabel(
        'Accessibility',
        'The core enforcement engine — app usage detection, limits, block screen.',
      );
    case PermissionKind.notificationListener:
      return const _RecoveryLabel(
        'Notification Access',
        'Lets Ulimit batch or mute notifications during focus sessions.',
      );
    case PermissionKind.vpn:
      return const _RecoveryLabel(
        'VPN & Network',
        'Local on-device filter for internet and website blocking.',
      );
    case PermissionKind.deviceAdmin:
      return const _RecoveryLabel(
        'Device Admin',
        'Blocks uninstall/force-stop as a bypass route.',
      );
    case PermissionKind.biometric:
      return const _RecoveryLabel('Biometrics', 'Optional');
    case PermissionKind.usageAccess:
      return const _RecoveryLabel(
        'Usage Access',
        'Exact per-app screen time from the system for the dashboard charts.',
      );
  }
}