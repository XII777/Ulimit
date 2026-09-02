/// Screen-time exclusions.
///
/// Daily screen time must count only apps the user actually OPENED —
/// never the home screen/launcher, OS chrome, or Ulimit itself (its own
/// foreground is not part of the wellbeing budget). Applied at WRITE time
/// (UsageStatsSync + UsageTracker) AND read time (today/weekly providers),
/// so the ring, charts, per-app stats and limits can never disagree.
bool isExcludedFromScreenTime(String packageName) {
  if (packageName.isEmpty) return true;
  // Our own app is never part of the user's screen time.
  if (packageName == 'com.ulimit.app') return true;
  // System UI (shade, recents, keyguard) is OS chrome, not an app.
  if (packageName == 'com.android.systemui') return true;
  if (_excludedPackages.contains(packageName)) return true;
  // Generic catch for custom/unknown launchers — every home-shell
  // package carries "launcher" in its name (Xiaomi uses com.miui.home,
  // covered explicitly above).
  return packageName.contains('launcher');
}

/// Known home-screen launchers per OEM skin (plus AOSP/Lineage/stock).
const Set<String> _excludedPackages = <String>{
  'com.android.launcher',
  'com.android.launcher2',
  'com.android.launcher3',
  'com.google.android.apps.nexuslauncher', // Pixel / stock AOSP
  'com.sec.android.app.launcher', // Samsung One UI
  'com.samsung.android.launcher',
  'com.miui.home', // Xiaomi / Redmi / POCO
  'com.oplus.launcher', // OnePlus / Oppo (ColorOS 13+)
  'com.coloros.launcher', // Oppo
  'com.bbk.launcher', // Vivo / BBK
  'com.bbk.launcher2',
  'com.vivo.launcher',
  'com.huawei.android.launcher', // Huawei
  'com.hihonor.launcher', // Honor
  'com.oneplus.launcher',
  'com.nothing.launcher', // Nothing Phone
  'org.lineageos.launcher3', // LineageOS
};
