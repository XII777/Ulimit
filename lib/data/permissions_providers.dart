import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/native/permissions_channel.dart';
import 'providers.dart';

/// Bumped to force every permission provider to re-check native state —
/// call `ref.invalidate` via this after returning from system Settings
/// (Android gives no callback for "user came back from Settings", so
/// polling on resume is the standard, correct pattern here).
final permissionsRefreshTickProvider = StateProvider<int>((ref) => 0);

/// True once the user has completed the permissions onboarding step.
/// Existing installs get this set during the v5 database migration, so
/// an app update that resets Android's privileged-access grants
/// (accessibility / notification listener — Android re-claims these on
/// every package update by design) shows a compact re-enable screen
/// instead of the full first-launch wizard.
final permissionsOnboardingCompletedProvider = StreamProvider<bool>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.ulimitSettings).watchSingle().map((s) => s.permissionsOnboardingCompleted);
});

final accessibilityEnabledProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isAccessibilityEnabled();
});

final deviceAdminActiveProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isDeviceAdminActive();
});

final notificationListenerEnabledProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isNotificationListenerEnabled();
});

final vpnPermissionGrantedProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.hasVpnPermission();
});

final postNotificationsGrantedProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isPostNotificationsGranted();
});

final biometricAvailableProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isBiometricAvailable();
});

final usageAccessGrantedProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isUsageAccessGranted();
});

final overlayGrantedProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isOverlayGranted();
});

/// Device Admin is requested during onboarding but never *required* —
/// tapping "Allow" opens the system dialog once; whatever the user
/// decides there, onboarding treats the card as handled so it never
/// blocks app access. This flag is what lets the card show "Done"
/// even when the native isDeviceAdminActive() check is still false.
/// The real, persistent toggle for actually enabling it lives in the
/// Parental & Lock screen instead.
final deviceAdminAcknowledgedProvider = StateProvider<bool>((ref) => false);

/// One combined item type the onboarding screen renders from — keeps
/// the widget dumb (map over a list) instead of five near-identical
/// card widgets hand-wired to five different providers.
enum PermissionKind {
  accessibility,
  vpn,
  deviceAdmin,
  notificationListener,
  biometric,
  usageAccess,
  overlayPermission,
}

class PermissionStatus {
  const PermissionStatus({required this.kind, required this.granted, required this.loading});
  final PermissionKind kind;
  final bool granted;
  final bool loading;
}

final allPermissionsProvider = Provider<List<PermissionStatus>>((ref) {
  final accessibility = ref.watch(accessibilityEnabledProvider);
  final vpn = ref.watch(vpnPermissionGrantedProvider);
  final deviceAdmin = ref.watch(deviceAdminActiveProvider);
  final notifications = ref.watch(notificationListenerEnabledProvider);
  final biometric = ref.watch(biometricAvailableProvider);
  final usageAccess = ref.watch(usageAccessGrantedProvider);
  final overlay = ref.watch(overlayGrantedProvider);

  final deviceAdminAcknowledged = ref.watch(deviceAdminAcknowledgedProvider);

  PermissionStatus build(PermissionKind kind, AsyncValue<bool> value) => PermissionStatus(
        kind: kind,
        granted: value.valueOrNull ?? false,
        loading: value.isLoading,
      );

  return [
    build(PermissionKind.accessibility, accessibility),
    build(PermissionKind.vpn, vpn),
    // Shows "Done" once either the OS reports it active, or the user
    // has been through the request flow once this session — see
    // deviceAdminAcknowledgedProvider's doc comment.
    PermissionStatus(
      kind: PermissionKind.deviceAdmin,
      granted: (deviceAdmin.valueOrNull ?? false) || deviceAdminAcknowledged,
      loading: deviceAdmin.isLoading,
    ),
    build(PermissionKind.notificationListener, notifications),
    build(PermissionKind.biometric, biometric),
    // Optional enhancement, not required: gives exact screen-time data
    // from UsageStatsManager (Digital Wellbeing's source) for the
    // dashboard charts. Never blocks app access.
    build(PermissionKind.usageAccess, usageAccess),
    // Optional hardening, not required: lets the standalone blocking
    // service draw the block screen itself when accessibility is off.
    build(PermissionKind.overlayPermission, overlay),
  ];
});

/// True once every *required* permission is granted. Device Admin,
/// Biometrics and VPN are all deliberately excluded: Biometrics is
/// genuinely optional, Device Admin — while useful for Invincible Mode's
/// tamper resistance — shouldn't block someone from using the app at
/// all just because they declined a device-admin prompt on first run,
/// and the VPN consent is only needed for the DNS-filter firewall (a
/// separate feature) — it must never gate app blocking behind it. They
/// are offered again, properly, from their own screens.
final requiredPermissionsGrantedProvider = Provider<bool>((ref) {
  final all = ref.watch(allPermissionsProvider);
  // Biometrics is genuinely optional; Device Admin is offered (not
  // required) so onboarding never blocks on a device-admin prompt;
  // VPN consent can be finicky on some OEMs and is only the DNS-filter
  // feature — never a gate for app blocking.
  const notRequired = {
    PermissionKind.biometric,
    PermissionKind.deviceAdmin,
    PermissionKind.vpn,
    PermissionKind.overlayPermission,
  };
  return all.where((p) => !notRequired.contains(p.kind)).every((p) => p.granted);
});
