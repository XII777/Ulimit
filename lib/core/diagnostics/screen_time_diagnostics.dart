import 'dart:io';

import '../native/permissions_channel.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../data/screen_time_filter.dart';
import '../../data/usage_merge.dart';
import '../../data/usage_stats_sync.dart';
import '../../data/usage_tracker.dart';
import 'diagnostics_log.dart';

/// One pass/fail verdict for the Screen Time Engine section.
class EngineCheck {
  const EngineCheck({required this.label, required this.pass, this.detail});

  final String label;
  final bool? pass; // null = pending / not applicable
  final String? detail;

  String get mark => pass == null ? '–' : (pass! ? 'OK' : 'FAIL');
}

/// A per-package comparison row: what the OS says vs what we store.
class UsageCompareRow {
  const UsageCompareRow({
    required this.package,
    required this.osSeconds,
    required this.trackerSeconds,
    required this.effectiveSeconds,
  });

  final String package;
  final int osSeconds;
  final int trackerSeconds;
  final int effectiveSeconds;

  /// OS-vs-effective gap, in seconds. A positive gap means our number
  /// is HIGHER than the OS's (the over-count class of bugs).
  int get overOs => effectiveSeconds - osSeconds;
}

/// The full copyable screen-time report. "Is the feature on — and is it
/// actually working?" answered per layer, plus the raw data needed to
/// debug a mismatch against Digital Wellbeing.
class ScreenTimeReport {
  ScreenTimeReport({
    required this.checks,
    required this.todayRows,
    required this.lastSyncNote,
    required this.eventLog,
    required this.device,
    required this.rawEvents,
    required this.generatedAt,
  });

  final List<EngineCheck> checks;
  final List<UsageCompareRow> todayRows;
  final String lastSyncNote;
  final List<DiagnosticsEntry> eventLog;
  final String device;
  final List<String> rawEvents;
  final DateTime generatedAt;

  int get overCountTotal {
    var sum = 0;
    for (final r in todayRows) {
      if (r.overOs > 0) sum += r.overOs;
    }
    return sum;
  }

  String render() {
    final b = StringBuffer();
    b.writeln('=== ULIMIT SCREEN-TIME REPORT ===');
    b.writeln('generated: $generatedAt');
    b.writeln('device: $device');
    b.writeln('app: usage engine v2 (OS-column merge)');
    b.writeln();
    b.writeln('--- CHECKS ---');
    for (final c in checks) {
      b.write('${c.mark.padRight(4)} ${c.label}');
      if (c.detail != null && c.detail!.isNotEmpty) b.write(' — ${c.detail}');
      b.writeln();
    }
    b.writeln();
    b.writeln('--- OS SYNC ---');
    b.writeln(lastSyncNote);
    b.writeln();
    b.writeln('--- TODAY PER APP (seconds) ---');
    b.writeln('package | os | tracker | shown | over-OS');
    for (final r in todayRows) {
      b.writeln(
          '${r.package} | ${r.osSeconds} | ${r.trackerSeconds} | ${r.effectiveSeconds} | ${r.overOs > 0 ? '+${r.overOs}' : '0'}');
    }
    if (todayRows.isEmpty) b.writeln('(no rows for today)');
    b.writeln();
    b.writeln('--- OVER-COUNT VS OS (today total) ---');
    final over = overCountTotal;
    b.writeln(over > 0
        ? '+$over s — our shown total EXCEEDS the OS; paste this report to support'
        : '0 s — shown total matches the OS source');
    b.writeln();
    b.writeln('--- RAW OS EVENTS (last ${rawEvents.length}) ---');
    for (final e in rawEvents) {
      b.writeln(e);
    }
    if (rawEvents.isEmpty) b.writeln('(none — usage access not granted or no events today)');
    b.writeln();
    b.writeln('--- EVENT LOG (last ${eventLog.length}) ---');
    for (final e in eventLog) {
      b.writeln('${e.at.toIso8601String()} $e');
    }
    if (eventLog.isEmpty) b.writeln('(empty)');
    return b.toString();
  }
}

/// Builds the report. All IO happens here so the UI only calls one
/// async function.
class ScreenTimeDiagnostics {
  ScreenTimeDiagnostics(this._db);

  final AppDatabase _db;

  Future<ScreenTimeReport> build({int rawEventLimit = 250}) async {
    final generatedAt = DateTime.now();
    final checks = <EngineCheck>[];

    // 1. Permission states ------------------------------------------------
    final usageGranted = await NativePermissions.isUsageAccessGranted();
    final accessibilityEnabled = await NativePermissions.isAccessibilityEnabled();
    checks.add(EngineCheck(
      label: 'Usage access permission',
      pass: usageGranted,
      detail: usageGranted ? 'Granted' : 'Not granted — app runs on tracker-only numbers; grant in Settings → Usage access',
    ));

    // 2. Feature on vs actually working ----------------------------------
    final native = await NativePermissions.fetchUsageDiagnostics();
    final nativeConnected = native['accessibilityConnected'] == true;
    final lastNativeEvent = (native['lastAccessibilityEventAt'] as num?)?.toInt() ?? 0;
    final lastScreenOff = (native['lastScreenOffAt'] as num?)?.toInt() ?? 0;
    final tracker = UsageTracker.instance;

    checks.add(EngineCheck(
      label: 'Accessibility service bound (native)',
      pass: nativeConnected,
      detail: nativeConnected ? 'Service instance alive' : 'Service not bound — enable in Settings → Accessibility',
    ));

    final lastDartEvent = UsageTracker.lastEventAt;
    final eventGapMin = lastDartEvent == null
        ? null
        : DateTime.now().difference(lastDartEvent).inMinutes;
    final dartReceiving = lastDartEvent != null &&
        eventGapMin! < 15 &&
        UsageTracker.eventsSeen > 0;
    checks.add(EngineCheck(
      label: 'Usage events reaching the tracker',
      pass: usageGranted == false ? null : (dartReceiving ? true : (UsageTracker.eventsSeen == 0 ? null : false)),
      detail: lastDartEvent == null
          ? 'No events since launch — switch apps once and re-open diagnostics'
          : 'Last event ${_ago(lastDartEvent)} · ${UsageTracker.eventsSeen} since launch'
              '${nativeConnected && !dartReceiving ? ' — native connected but Dart sees nothing: channel broken' : ''}',
    ));

    final screenBridgeFired = lastScreenOff > 0 || UsageTracker.lastScreenOffAt != null;
    checks.add(EngineCheck(
      label: 'Screen on/off bridge',
      pass: screenBridgeFired,
      detail: screenBridgeFired
          ? 'Screen-off seen ${_ago(UsageTracker.lastScreenOffAt ?? DateTime.fromMillisecondsSinceEpoch(lastScreenOff))}'
          : 'No screen-off observed since launch — turn the screen off/on once to verify',
    ));

    // 3. Sync state --------------------------------------------------------
    final syncOk = UsageStatsSyncState.lastSyncAt != null &&
        UsageStatsSyncState.lastError == null;
    checks.add(EngineCheck(
      label: 'OS usage sync (UsageStatsManager)',
      pass: usageGranted ? syncOk : null,
      detail: UsageStatsSyncState.lastSyncAt == null
          ? 'Never ran yet (first cycle pending)'
          : UsageStatsSyncState.lastError ??
              'Last run ${_ago(UsageStatsSyncState.lastSyncAt!)} — ${UsageStatsSyncState.lastRowsWritten} row(s)',
    ));

    // 4. Session state -----------------------------------------------------
    final fg = UsageTracker.liveForeground.value;
    checks.add(EngineCheck(
      label: fg == null
          ? 'Live session — none open'
          : 'Live session — ${fg.package}',
      pass: true,
      detail: fg == null
          ? 'Screen off or no foreground app tracked'
          : 'Started ${_ago(DateTime.fromMillisecondsSinceEpoch(fg.sinceMillis))}'
              '${fg.osSecondsAtSessionStart != null ? ' · OS snapshot ${fg.osSecondsAtSessionStart}s' : ' · snapshot pending'}',
    ));

    final pendingPkg = tracker?.pendingPackage;
    final pendingAt = tracker?.pendingTimestampMillis;
    checks.add(EngineCheck(
      label: 'Attribution state',
      pass: true,
      detail: pendingPkg == null
          ? 'No open window to attribute'
          : 'Pending: $pendingPkg since ${_ago(DateTime.fromMillisecondsSinceEpoch(pendingAt!))}',
    ));

    // 5. Today's numbers vs the OS ----------------------------------------
    final today = startOfDay(DateTime.now());
    final rows = await (_db.select(_db.appUsage)..where((t) => t.day.equals(today))).get();
    final todayRows = <UsageCompareRow>[
      for (final r in rows)
        if (!isExcludedFromScreenTime(r.packageName))
          UsageCompareRow(
            package: r.packageName,
            osSeconds: r.osForegroundSeconds,
            trackerSeconds: r.foregroundSeconds,
            effectiveSeconds: r.effectiveSeconds,
          ),
    ];
    todayRows.sort((a, b) => b.effectiveSeconds.compareTo(a.effectiveSeconds));

    // 6. Raw OS event stream ----------------------------------------------
    List<String> rawLines = [];
    List<Map<String, dynamic>> rawEvents = [];
    if (usageGranted) {
      rawEvents = await NativePermissions.fetchRawUsageEventsToday(limit: rawEventLimit);
      rawLines = [
        for (final e in rawEvents)
          '${DateTime.fromMillisecondsSinceEpoch((e['t'] as num).toInt()).toIso8601String()} type=${e['type']} ${e['pkg']}',
      ];
    }

    // 7. Device info -------------------------------------------------------
    String device;
    try {
      device = await _deviceInfo(native);
    } catch (_) {
      device = 'unknown';
    }

    final syncNote = StringBuffer();
    syncNote.writeln('last sync: ${UsageStatsSyncState.lastSyncAt?.toIso8601String() ?? 'never'}');
    syncNote.writeln('rows written last sync: ${UsageStatsSyncState.lastRowsWritten}');
    syncNote.writeln('last error: ${UsageStatsSyncState.lastError ?? 'none'}');
    syncNote.writeln('usage access granted: $usageGranted');
    syncNote.writeln('accessibility setting enabled: $accessibilityEnabled');
    syncNote.writeln('accessibility bound (native view): $nativeConnected');
    syncNote.writeln('last native event: ${lastNativeEvent == 0 ? 'never' : DateTime.fromMillisecondsSinceEpoch(lastNativeEvent).toIso8601String()}');
    syncNote.writeln('last screen-off (native): ${lastScreenOff == 0 ? 'never' : DateTime.fromMillisecondsSinceEpoch(lastScreenOff).toIso8601String()}');
    syncNote.writeln('tracker events since launch: ${UsageTracker.eventsSeen}');

    return ScreenTimeReport(
      checks: checks,
      todayRows: todayRows,
      lastSyncNote: syncNote.toString().trimRight(),
      eventLog: DiagnosticsLog.entries.take(40).toList(),
      device: device,
      rawEvents: rawLines,
      generatedAt: generatedAt,
    );
  }

  Future<String> _deviceInfo(Map<String, dynamic> native) async {
    final nativeDevice = native['device'];
    final sdk = native['sdk'];
    final version = native['appVersion'];
    if (nativeDevice != null && sdk != null) {
      return '$nativeDevice · Android $sdk · app $version · tz ${DateTime.now().timeZoneName}';
    }
    // Fallback: local platform only (tests / non-Android hosts).
    if (Platform.isAndroid) return 'Android · tz ${DateTime.now().timeZoneName}';
    return Platform.operatingSystem;
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 90) return '${d.inSeconds}s ago';
    if (d.inMinutes < 90) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }
}
