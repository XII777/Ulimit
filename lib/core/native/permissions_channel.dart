import 'package:flutter/services.dart';

/// Thin wrapper around the native MethodChannel. Every method here maps
/// 1:1 to a `when` branch in MainActivity.kt's onMethodCall — keep them
/// in sync if you add a new permission.
///
/// Android does not let an app silently grant Accessibility Service or
/// Notification Listener access — those two always require the user to
/// flip a toggle in system Settings, so their "request" methods open
/// Settings rather than showing an in-app dialog. Device Admin, VPN, and
/// POST_NOTIFICATIONS *do* support an in-app system dialog, so those
/// request methods trigger one directly.
class NativePermissions {
  NativePermissions._();
  static const _channel = MethodChannel('com.ulimit.app/permissions');

  static Future<bool> isAccessibilityEnabled() async {
    return await _channel.invokeMethod<bool>('isAccessibilityEnabled') ?? false;
  }

  static Future<void> openAccessibilitySettings() =>
      _channel.invokeMethod('openAccessibilitySettings');

  static Future<bool> isDeviceAdminActive() async {
    return await _channel.invokeMethod<bool>('isDeviceAdminActive') ?? false;
  }

  static Future<void> requestDeviceAdmin() => _channel.invokeMethod('requestDeviceAdmin');

  static Future<bool> isNotificationListenerEnabled() async {
    return await _channel.invokeMethod<bool>('isNotificationListenerEnabled') ?? false;
  }

  static Future<void> openNotificationListenerSettings() =>
      _channel.invokeMethod('openNotificationListenerSettings');

  static Future<bool> hasVpnPermission() async {
    return await _channel.invokeMethod<bool>('hasVpnPermission') ?? false;
  }

  static Future<void> requestVpnPermission() => _channel.invokeMethod('requestVpnPermission');

  static Future<bool> isPostNotificationsGranted() async {
    return await _channel.invokeMethod<bool>('isPostNotificationsGranted') ?? false;
  }

  static Future<void> requestPostNotifications() =>
      _channel.invokeMethod('requestPostNotifications');

  static Future<bool> isBiometricAvailable() async {
    return await _channel.invokeMethod<bool>('isBiometricAvailable') ?? false;
  }
}
