import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/native/permissions_channel.dart';
import 'db/app_database.dart';
import 'providers.dart';
import 'screen_time_filter.dart';

/// Syncs the authoritative per-app screen times from UsageStatsManager
/// (the OS's own usage stats — the same source Digital Wellbeing shows)
/// into the `app_usage` table.
///
/// Why: the accessibility tracker is excellent at *when* switches
/// happen, but its totals drift from the OS numbers over time (events
/// dropped when the service is briefly down, screen-off edges, etc.).
/// UsageStats is the ground truth for per-day durations, so we merge it
/// on app start, on resume, and on a slow cadence while foregrounded.
///
/// Merge semantics: screen time must reflect FOREGROUND use only. The OS
/// `totalTimeInForeground` from UsageStatsManager (the source Digital
/// Wellbeing shows) is the authoritative foreground-only measure, so it
/// always wins when present. The accessibility tracker is only used as a
/// fallback for seconds the OS hasn't reported yet (fresh use this
/// session) — its gap attribution can over-count (time across the
/// notification shade / app switcher / screen-off where no tracked
/// foreground event fires), so it must never extend the total above the
/// OS's real foreground figure.
class UsageStatsSync {
  UsageStatsSync(this._db);

  final AppDatabase _db;

  Future<void> syncHistory({int days = 90}) async {
    final granted = await NativePermissions.isUsageAccessGranted();
    if (!granted) return;

    final records = await NativePermissions.fetchDeviceUsageForDays(days);
    if (records.isEmpty) return;

    // Load existing tracker values for the same window so the merge is
    // read-before-write (not blindly overwriting tracker-only seconds).
    final start = DateTime.now().subtract(Duration(days: days));
    final existingRows = await (_db.select(_db.appUsage)
          ..where((t) => t.day.isBiggerOrEqualValue(start)))
        .get();
    final existing = <String, int>{
      for (final row in existingRows)
        '${row.packageName}|${row.day.millisecondsSinceEpoch ~/ 1000}': row.foregroundSeconds,
    };

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

        final trackerValue = existing['$package|$dayUnix'] ?? 0;
        // OS foreground is authoritative (foreground-only). The tracker
        // value is only a fallback for seconds the OS hasn't aggregated
        // yet — never a ceiling raiser, so over-counted gaps can't inflate
        // the total.
        final merged = screenTime > 0 ? screenTime : trackerValue;
        if (merged <= 0) continue;

        await _db.customStatement(
          '''
          INSERT INTO app_usage (package_name, day, foreground_seconds)
          VALUES (?, ?, ?)
          ON CONFLICT(package_name, day)
          DO UPDATE SET foreground_seconds = ?3
          ''',
          [package, dayUnix, merged],
        );
      }
    });
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
    _started = true;    final sync = ref.read(usageStatsSyncProvider);

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
