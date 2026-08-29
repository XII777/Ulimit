import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../core/native/permissions_channel.dart';
import '../../data/permissions_providers.dart';

class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key, required this.onAllGranted});

  /// Called once every non-optional permission is granted, so the
  /// caller can advance the router — kept as a callback rather than
  /// this screen owning navigation, so it's reusable from both first
  /// launch and Settings → Permissions.
  final VoidCallback onAllGranted;

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen>
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
    // correct, standard pattern is to re-check every relevant permission
    // when the app resumes, since that's the only reliable signal.
    if (state == AppLifecycleState.resumed) {
      ref.read(permissionsRefreshTickProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(allPermissionsProvider);

    // Biometric is optional (see design) — required count excludes it.
    const notRequired = {PermissionKind.biometric, PermissionKind.deviceAdmin};
    final required = permissions.where((p) => !notRequired.contains(p.kind));
    final grantedCount = required.where((p) => p.granted).length;
    final requiredTotal = required.length;
    final allRequiredGranted = grantedCount == requiredTotal;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            children: [
              const SizedBox(height: 6),
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(Icons.lock_rounded, color: AppColors.inkDim, size: 22),
              ),
              const SizedBox(height: 12),
              Text(
                'Ulimit needs a few permissions',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              Text(
                'Everything stays on your device — nothing is ever uploaded. '
                'Each permission only powers the feature next to it.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView.separated(
                  itemCount: permissions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _PermissionCard(status: permissions[i]),
                ),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: requiredTotal == 0 ? 0 : grantedCount / requiredTotal,
                  minHeight: 5,
                  backgroundColor: AppColors.stroke,
                  valueColor: const AlwaysStoppedAnimation(AppColors.ink),
                ),
              ),
              const SizedBox(height: 8),
              Text('$grantedCount of $requiredTotal granted',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: allRequiredGranted ? widget.onAllGranted : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.ink,
                    disabledBackgroundColor: AppColors.surface2,
                    padding: const EdgeInsets.all(15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: Text(
                    'Continue',
                    style: TextStyle(
                      color: allRequiredGranted ? AppColors.bg : AppColors.inkFaint,
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
}

class _PermissionMeta {
  const _PermissionMeta(this.title, this.description, this.icon, this.iconColor, this.optional);
  final String title;
  final String description;
  final IconData icon;
  final Color iconColor;
  final bool optional;
}

const _meta = {
  PermissionKind.accessibility: _PermissionMeta(
    'Accessibility',
    'The core engine — detects app usage, enforces limits, and shows the block screen instantly.',
    Icons.visibility_rounded,
    AppColors.inkDim,
    false,
  ),
  PermissionKind.vpn: _PermissionMeta(
    'VPN & Network',
    'Creates a local, on-device filter for internet and website blocking.',
    Icons.public_rounded,
    AppColors.inkDim,
    false,
  ),
  PermissionKind.deviceAdmin: _PermissionMeta(
    'Device Admin',
    "Stops Ulimit from being uninstalled or force-stopped to bypass a limit. "
    "Optional here — you can turn this on later in Parental & Lock.",
    Icons.shield_rounded,
    AppColors.inkDim,
    false,
  ),
  PermissionKind.notificationListener: _PermissionMeta(
    'Notification Access',
    'Lets Ulimit batch or mute notifications during focus sessions.',
    Icons.notifications_rounded,
    AppColors.inkDim,
    false,
  ),
  PermissionKind.biometric: _PermissionMeta(
    'Biometrics',
    'Optional — protects your limits from being changed by others.',
    Icons.fingerprint_rounded,
    AppColors.inkDim,
    true,
  ),
};

class _PermissionCard extends ConsumerWidget {
  const _PermissionCard({required this.status});
  final PermissionStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = _meta[status.kind]!;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: meta.iconColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(meta.icon, size: 15, color: meta.iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(meta.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13)),
                const SizedBox(height: 2),
                Text(meta.description, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _ActionButton(status: status, optional: meta.optional),
        ],
      ),
    );
  }
}

class _ActionButton extends ConsumerWidget {
  const _ActionButton({required this.status, required this.optional});
  final PermissionStatus status;
  final bool optional;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (status.granted) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(AppRadius.pill)),
        child: const Text('✓ Done', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.bg)),
      );
    }

    return GestureDetector(
      onTap: status.loading ? null : () => _handleTap(ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: optional ? AppColors.surface2 : AppColors.accent,
          border: optional ? Border.all(color: AppColors.stroke) : null,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          optional ? 'Skip' : 'Allow',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: optional ? AppColors.inkDim : AppColors.bg,
          ),
        ),
      ),
    );
  }

  Future<void> _handleTap(WidgetRef ref) async {
    // Accessibility and Notification Listener can only be toggled from
    // system Settings — Android has no in-app grant dialog for either.
    // The rest support a direct system dialog.
    switch (status.kind) {
      case PermissionKind.accessibility:
        await NativePermissions.openAccessibilitySettings();
      case PermissionKind.notificationListener:
        await NativePermissions.openNotificationListenerSettings();
      case PermissionKind.vpn:
        await NativePermissions.requestVpnPermission();
      case PermissionKind.deviceAdmin:
        // Fire the system dialog, but don't wait on or gate anything
        // to its result — whatever the user picks there, onboarding
        // moves on. See deviceAdminAcknowledgedProvider's doc comment.
        await NativePermissions.requestDeviceAdmin();
        ref.read(deviceAdminAcknowledgedProvider.notifier).state = true;
      case PermissionKind.biometric:
        // "Skip" for the optional card — nothing to request, just move
        // on; availability is a device capability, not a togglable
        // permission, so there's nothing else to do here.
        return;
    }
    // VPN/Device Admin dialogs resolve synchronously enough that an
    // immediate re-check is worthwhile; Accessibility/Notification
    // Listener rely on the lifecycle-resume re-check instead since the
    // user is leaving the app to a Settings screen.
    ref.read(permissionsRefreshTickProvider.notifier).state++;
  }
}
