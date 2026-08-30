import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/native/enforcement_channel.dart';

/// Device-level VPN state, refreshed after every toggle and on resume.
class VpnStatus {
  const VpnStatus({required this.running, required this.prepared});
  final bool running;
  final bool prepared; // user consent already granted at OS level
}

final vpnStatusProvider = FutureProvider<VpnStatus>((ref) async {
  final running = await EnforcementChannel.isVpnRunning();
  return VpnStatus(running: running, prepared: true);
});

/// Installed-app catalog from PackageManager. Loaded once per app run
/// and kept alive — the catalog is read-mostly; a pull-to-refresh
/// invalidates it explicitly. Icons ship as raw PNG bytes over the
/// channel, cached alongside.
class AppsCatalog {
  AppsCatalog(this.apps) {
    byPackage = {for (final a in apps) a.packageName: a};
  }

  final List<InstalledApp> apps;
  late final Map<String, InstalledApp> byPackage;

  /// Icon bytes for a package; null → the UI draws a neutral glyph.
  Uint8List? iconFor(String packageName) => byPackage[packageName]?.iconBytes;

  String nameFor(String packageName) => byPackage[packageName]?.displayName ?? packageName;
}

final appsCatalogProvider = FutureProvider<AppsCatalog>((ref) async {
  final apps = await EnforcementChannel.getInstalledApps();
  return AppsCatalog(apps);
});

/// Cached icon-decode dedup: decoding 200+ PNGs per list build is
/// wasteful; screens use this provider keyed by package.
final appIconProvider = FutureProvider.family<Uint8List?, String>((ref, packageName) async {
  final catalog = await ref.watch(appsCatalogProvider.future);
  return catalog.iconFor(packageName);
});
