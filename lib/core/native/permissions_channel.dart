import 'dart:convert';

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

  /// Usage access (UsageStatsManager special permission, granted in
  /// system Settings → Usage access). When granted the app reads the
  /// authoritative per-app foreground times for exact dashboard charts.
  static Future<bool> isUsageAccessGranted() async {
    return await _channel.invokeMethod<bool>('isUsageAccessGranted') ?? false;
  }

  static Future<void> openUsageAccessSettings() =>
      _channel.invokeMethod('openUsageAccessSettings');

  /// Per-package daily foreground seconds for the last [days] days from
  /// UsageStatsManager; decoded as [{packageName, day, screenTime}].
  static Future<List<Map<String, dynamic>>> fetchDeviceUsageForDays(int days) async {
    try {
      final raw = await _channel.invokeMethod<String>('fetchDeviceUsageForDays', days);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on PlatformException {
      return [];
    }
  }

  /// Today's 24 per-hour foreground-second buckets for [packageName]
  /// (index 0 = 00:00–00:59 … 23 = 23:00–23:59), from UsageEvents.
  static Future<List<int>> fetchAppHourlyUsage(String packageName) async {
    try {
      final raw = await _channel.invokeMethod<String>('fetchAppHourlyUsage', packageName);
      if (raw == null || raw.isEmpty) return List.filled(24, 0);
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => (e as num).toInt()).toList();
    } on PlatformException {
      return List.filled(24, 0);
    }
  }

  /// Today's device-wide per-hour foreground seconds (all apps summed,
  /// Ulimit + launcher excluded), index 0 = 00:00–00:59 … 23.
  static Future<List<int>> fetchDeviceHourlyUsage() async {
    try {
      final raw = await _channel.invokeMethod<String>('fetchDeviceHourlyUsage');
      if (raw == null || raw.isEmpty) return List.filled(24, 0);
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => (e as num).toInt()).toList();
    } on PlatformException {
      return List.filled(24, 0);
    }
  }

  /// Shows the system BiometricPrompt (or device credential fallback)
  /// and resolves true only on success. Used by Invincible Mode before
  /// restriction changes and by early-ending an invincible session.
  static Future<bool> authenticate({required String reason}) async {
    try {
      return await _channel.invokeMethod<bool>('authenticate', reason) ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Writes [json] to a user-visible file (Downloads via MediaStore on
  /// API 29+, app documents otherwise) and returns the resulting path,
  /// or null on failure.
  static Future<String?> exportFile(String json) async {
    try {
      return await _channel.invokeMethod<String>('exportData', json);
    } on PlatformException {
      return null;
    }
  }

  /// Opens the system document picker and returns the selected file's
  /// text content, or null when cancelled.
  static Future<String?> importFile() async {
    try {
      return await _channel.invokeMethod<String>('importData');
    } on PlatformException {
      return null;
    }
  }
}
