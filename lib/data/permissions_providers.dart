import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/native/permissions_channel.dart';

/// Bumped to force every permission provider to re-check native state —
/// call `ref.invalidate` via this after returning from system Settings
/// (Android gives no callback for "user came back from Settings", so
/// polling on resume is the standard, correct pattern here).
final permissionsRefreshTickProvider = StateProvider<int>((ref) => 0);

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

/// One combined item type the onboarding screen renders from — keeps
/// the widget dumb (map over a list) instead of five near-identical
/// card widgets hand-wired to five different providers.
enum PermissionKind { accessibility, vpn, deviceAdmin, notificationListener, biometric }

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

  PermissionStatus build(PermissionKind kind, AsyncValue<bool> value) => PermissionStatus(
        kind: kind,
        granted: value.valueOrNull ?? false,
        loading: value.isLoading,
      );

  return [
    build(PermissionKind.accessibility, accessibility),
    build(PermissionKind.vpn, vpn),
    build(PermissionKind.deviceAdmin, deviceAdmin),
    build(PermissionKind.notificationListener, notifications),
    build(PermissionKind.biometric, biometric),
  ];
});

/// True once every *required* permission (all but the optional
/// biometric) is granted. Drives the app-level gate in main.dart — once
/// this flips true, Home renders automatically, no manual navigation
/// needed.
final requiredPermissionsGrantedProvider = Provider<bool>((ref) {
  final all = ref.watch(allPermissionsProvider);
  return all
      .where((p) => p.kind != PermissionKind.biometric)
      .every((p) => p.granted);
});
