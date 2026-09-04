import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnostics/diagnostics_log.dart';
import '../core/native/permissions_channel.dart';
import 'db/app_database.dart';
import 'providers.dart';
import 'screen_time_filter.dart';

/// Syncs the authoritative per-app screen times from UsageStatsManager
/// (the OS's own usage stats — the same source Digital Wellbeing shows)
/// into the `os_foreground_seconds` column of the `app_usage` table.
///
/// Why: the accessibility tracker is excellent at *when* switches
/// happen, but its totals drift from the OS numbers over time (events
/// dropped when the service is briefly down, screen-off edges, etc.).
/// UsageStats is the ground truth for per-day durations, so we merge it
/// on app start, on resume, and on a slow cadence while foregrounded.
///
/// Merge semantics: the OS value is written to its OWN column and never
/// mixed with the tracker's. The user-visible number is
/// [mergedUsageSeconds] — OS wins when present, tracker fills the gap
/// (fresh seconds this session, or no usage-access permission). The old
/// single-column replace-then-increment design let a tracker
/// attribution stack on top of an OS value that already contained the
/// same session — the main reason our total exceeded Digital
/// Wellbeing's.
class UsageStatsSync {
  UsageStatsSync(this._db);

  final AppDatabase _db;

  Future<void> syncHistory({int days = 90}) async {
    final granted = await NativePermissions.isUsageAccessGranted();
    if (!granted) {
      UsageStatsSyncState.noteSync(rowsWritten: 0, error: 'usage access not granted');
      return;
    }

    final records = await NativePermissions.fetchDeviceUsageForDays(days);
    if (records.isEmpty) {
      UsageStatsSyncState.noteSync(rowsWritten: 0, error: 'OS returned no usage records');
      return;
    }

    var written = 0;
    // Batched write in one transaction (no per-row autocommit churn).
    await _db.transaction(() async {
      for (final record in records) {
        final package = record['packageName'] as String?;
        final dayUnix = record['day'] as int?;
        final screenTime = record['screenTime'] as int?;
        if (package == null || dayUnix == null || screenTime == null) continue;
        // Screen time counts OPENED APPS only — never the home screen/
        // launcher, system UI, or Ulimit itself (see screen_time_filter).
        if (isExcludedFromScreenTime(package)) continue;
        if (screenTime <= 0) continue;

        // OS value into its own column; the tracker column is zeroed
        // for the row so the displayed merge (OS wins when present,
        // else tracker) reads EXACTLY the OS number for every
        // OS-covered day — no tracker seconds can stack on top. When
        // usage access is absent this sync never runs and the tracker
        // column remains the (capped, approximate) fallback.
        await _db.customStatement(
          '''
          INSERT INTO app_usage (package_name, day, foreground_seconds, os_foreground_seconds)
          VALUES (?, ?, 0, ?)
          ON CONFLICT(package_name, day)
          DO UPDATE SET
            os_foreground_seconds = excluded.os_foreground_seconds,
            foreground_seconds = 0
          ''',
          [package, dayUnix, screenTime],
        );
        written++;
      }
    });

    UsageStatsSyncState.noteSync(rowsWritten: written, error: null);
  }
}

/// Observable state of the sync loop — read by the diagnostics report
/// ("is the OS sync actually running?") and logged per cycle.
class UsageStatsSyncState {
  UsageStatsSyncState._();

  static DateTime? lastSyncAt;
  static int lastRowsWritten = 0;
  static String? lastError;

  static void noteSync({required int rowsWritten, required String? error}) {
    lastSyncAt = DateTime.now();
    lastRowsWritten = rowsWritten;
    lastError = error;
    if (error != null) {
      DiagnosticsLog.record('OS usage sync failed: $error', tag: 'sync');
    } else {
      DiagnosticsLog.record('OS usage sync: $rowsWritten row(s) updated', tag: 'sync');
    }
  }
}

final usageStatsSyncProvider = Provider<UsageStatsSync>((ref) {
  return UsageStatsSync(ref.watch(databaseProvider));
});

/// Wires the sync: runs once on start, on every resume from background,
/// and every 30s while foregrounded. Stopped implicitly when the
/// provider is disposed (the timer is not retained after — the
/// coordinator is a singleton, so it lives as long as the app).
class UsageStatsSyncCoordinator {
  UsageStatsSyncCoordinator._();

  static final UsageStatsSyncCoordinator instance = UsageStatsSyncCoordinator._();

  bool _started = false;

  void start(WidgetRef ref) {
    if (_started) return;
    _started = true;
    final sync = ref.read(usageStatsSyncProvider);

    WidgetsBinding.instance.addObserver(AppLifecycleObserver((state) {
      if (state == AppLifecycleState.resumed) sync.syncHistory();
    }));
    Timer.periodic(const Duration(seconds: 30), (_) => sync.syncHistory());
    // Kick immediately too (first frame after boot).
    sync.syncHistory();
  }
}

/// WidgetsBindingObserver trampoline (the observer interface can't be
/// given a lambda directly).
class AppLifecycleObserver extends WidgetsBindingObserver {
  AppLifecycleObserver(this._onChange);
  final void Function(AppLifecycleState) _onChange;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _onChange(state);
}
