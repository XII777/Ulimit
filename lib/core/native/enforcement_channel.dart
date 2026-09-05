import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Dart → native enforcement bridge. Everything the Android layer needs
/// to enforce policies while Ulimit itself is not on screen flows
/// through here as a single JSON snapshot (plus the domain filter file
/// for the VPN, which is too large for a channel message).
///
/// Design rule: Dart is the source of truth for policy; native is the
/// realtime evaluator that applies simple, locally-computable checks
/// (timestamp expiry, minute-of-day windows, usage thresholds) against
/// the snapshot. No business logic duplication beyond that.
class EnforcementChannel {
  EnforcementChannel._();

  static const _channel = MethodChannel('com.ulimit.app/enforcement');

  /// Pushes a full policy snapshot to native (persisted to SharedPreferences
  /// so the AccessibilityService / VPN / boot receiver can read it even
  /// after process death).
  static Future<void> pushSnapshot(Map<String, dynamic> snapshot) async {
    try {
      await _channel.invokeMethod('pushSnapshot', snapshot);
    } on PlatformException {
      // Native side not ready (e.g. during hot restart) — the next
      // push after any state change re-syncs; nothing is lost because
      // every caller re-pushes on every relevant DB change.
    } on MissingPluginException {
      // Running in a test or on a non-Android platform.
    }
  }

  /// Signals native that the domain filter file has changed. The VPN
  /// reloads it without a reconnect.
  static Future<void> reloadDomainFilter() async {
    try {
      await _channel.invokeMethod('reloadDomainFilter');
    } on PlatformException {
      /* VPN may not be running — nothing to reload into. */
    } on MissingPluginException {
      /* Non-Android. */
    }
  }

  /// Asks the accessibility layer to re-check whatever app is in the
  /// foreground RIGHT NOW — called right after a policy push so a block
  /// added mid-session (e.g. a doomscroll count just crossed) bites
  /// instantly instead of on the next app switch.
  static Future<void> reevaluateForeground() async {
    try {
      await _channel.invokeMethod('reevaluateForeground');
    } on PlatformException {
      /* best-effort */
    } on MissingPluginException {
      /* non-Android */
    }
  }

  /// Path native expects the blocked-domains file at (inside the app's
  /// filesDir, which Dart can write to directly).
  static Future<String> filterFilePath() async {
    try {
      return await _channel.invokeMethod<String>('getFilterFilePath') ?? '';
    } on PlatformException {
      return '';
    } on MissingPluginException {
      return '';
    }
  }

  /// Live enforcement diagnostics from the native blocking engine:
  /// snapshot presence, actuator/overlay/service status and a ring
  /// buffer of recent block/eject events. Debugging aid.
  static Future<String> enforcementStatus() async {
    try {
      return await _channel.invokeMethod<String>('getEnforcementStatus') ?? '';
    } on PlatformException {
      return '';
    } on MissingPluginException {
      return '';
    }
  }

  static Future<bool> startVpn() async {
    try {
      return await _channel.invokeMethod<bool>('startVpn') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> stopVpn() async {
    try {
      return await _channel.invokeMethod<bool>('stopVpn') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> isVpnRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isVpnRunning') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> setDnd(bool enabled) async {
    try {
      await _channel.invokeMethod('setDnd', enabled);
    } on PlatformException {
      /* DND policy access missing — UI surfaces the request. */
    } on MissingPluginException {
      /* Non-Android. */
    }
  }

  /// Enables/disables the system-wide bedtime grayscale effect. Uses
  /// the Android 15+ Do-Not-Disturb device-effect API; a no-op before
  /// API 35 or without DND policy access.
  static Future<void> setBedtimeGrayscale(bool enabled) async {
    try {
      await _channel.invokeMethod('setBedtimeGrayscale', enabled);
    } on PlatformException {
      /* DND policy access missing — grayscale is best-effort. */
    } on MissingPluginException {
      /* Non-Android. */
    }
  }

  static Future<bool> isDndAccessGranted() async {
    try {
      return await _channel.invokeMethod<bool>('isDndAccessGranted') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> openDndAccessSettings() async {
    try {
      await _channel.invokeMethod('openDndAccessSettings');
    } on PlatformException {
      /* Non-Android. */
    } on MissingPluginException {
      /* Non-Android. */
    }
  }

  static Future<void> setBedtimeAlarms({
    required bool enabled,
    required String startTime,
    required String endTime,
  }) async {
    try {
      await _channel.invokeMethod('setBedtimeAlarms', {
        'enabled': enabled,
        'startTime': startTime,
        'endTime': endTime,
      });
    } on PlatformException {
      /* Non-Android / scheduler unavailable. */
    } on MissingPluginException {
      /* Non-Android. */
    }
  }

  // -----------------------------------------------------------------
  // Focus Session indicator (Android foreground service + notification)
  // -----------------------------------------------------------------

  static Future<void> Function(String action)? _focusActionHandler;

  /// Registers the Dart handler the Android indicator service invokes
  /// for Pause/Resume/End. Works in both the app engine and the
  /// background engine — the service picks whichever is alive.
  static void setFocusActionHandler(Future<void> Function(String action)? handler) {
    _focusActionHandler = handler;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'focusAction') {
        final handler = _focusActionHandler;
        if (handler != null) {
          await handler(call.arguments['action'] as String? ?? '');
        }
        return null;
      }
      return null; // unknown Kotlin→Dart calls are ignored
    });
  }

  static Future<void> startFocusIndicator({
    required String label,
    required DateTime startedAt,
    required DateTime endsAt,
    required bool paused,
    String? doomPackage,
    int doomCount = 0,
  }) async {
    try {
      await _channel.invokeMethod('startFocusIndicator', {
        'label': label,
        'startedAtMillis': startedAt.millisecondsSinceEpoch,
        'endMillis': endsAt.millisecondsSinceEpoch,
        'paused': paused,
        if (doomPackage != null) 'doomPackage': doomPackage,
        'doomCount': doomCount,
      });
    } on PlatformException {
      /* indicator is best-effort presentation */
    } on MissingPluginException {
      /* non-Android */
    }
  }

  static Future<void> updateFocusNotification({
    required String label,
    required DateTime endsAt,
    required bool paused,
    String? doomPackage,
    int doomCount = 0,
  }) async {
    try {
      await _channel.invokeMethod('updateFocusNotification', {
        'label': label,
        'endMillis': endsAt.millisecondsSinceEpoch,
        'paused': paused,
        if (doomPackage != null) 'doomPackage': doomPackage,
        'doomCount': doomCount,
      });
    } on PlatformException {
    } on MissingPluginException {
    }
  }

  static Future<void> stopFocusIndicator() async {
    try {
      await _channel.invokeMethod('stopFocusIndicator');
    } on PlatformException {
    } on MissingPluginException {
    }
  }

  /// Installed launchable apps: [{package, name, icon (PNG bytes)}].
  static Future<List<InstalledApp>> getInstalledApps() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('getInstalledApps');
      if (raw == null) return const [];
      return [
        for (final item in raw)
          InstalledApp(
            packageName: item['package'] as String,
            displayName: item['name'] as String? ?? item['package'] as String,
            iconBytes: item['icon'] as Uint8List?,
          ),
      ];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }
}

class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.displayName,
    this.iconBytes,
  });

  final String packageName;
  final String displayName;
  final Uint8List? iconBytes;
}

/// Writes the enabled-domain filter file and asks native to reload it.
/// Kept as a small service rather than inline logic so every writer
/// (custom rule toggle, list download, category toggle) produces an
/// identical, atomic update. An optional sources sidecar (`domain|Human
/// label`) lets the browser block page name WHICH filter caught a hit.
class DomainFilterSync {
  DomainFilterSync(this._path);

  final String _path;

  static const _placeholder = '';

  String get _sourcesPath =>
      p.join(p.dirname(_path), 'blocked_domain_sources.txt');

  Future<void> sync(
      Set<String> enabledDomains, Map<String, String> sources) async {
    if (_path.isEmpty) return;
    final file = File(_path);
    final tmp = File(p.join(p.dirname(_path), '.${p.basename(_path)}.tmp'));
    await tmp.writeAsString(enabledDomains.join('\n'), flush: true);
    await tmp.rename(file.path);

    final srcFile = File(_sourcesPath);
    if (sources.isEmpty) {
      if (await srcFile.exists()) await srcFile.delete();
    } else {
      final srcTmp = File('$_sourcesPath.tmp');
      await srcTmp.writeAsString(
        sources.entries.map((e) => '${e.key}|${e.value}').join('\n'),
        flush: true,
      );
      await srcTmp.rename(srcFile.path);
    }

    await EnforcementChannel.reloadDomainFilter();
  }

  static Future<DomainFilterSync> create() async {
    final path = await EnforcementChannel.filterFilePath();
    return DomainFilterSync(path.isEmpty ? _placeholder : path);
  }
}
