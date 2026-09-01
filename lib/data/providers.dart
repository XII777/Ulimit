import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'db/app_database.dart';
import 'db/tables.dart';
import 'usage_tracker.dart';

/// Single DB instance for the app's lifetime. `keepAlive` so switching
/// tabs doesn't tear down and reopen the SQLite connection — that
/// reopen cost is exactly the kind of jank a "don't make it lag"
/// requirement is about.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

/// Re-evaluation tick for time-derived state (restriction expiry,
/// countdowns). 15s cadence: frequent enough that "Blocked until 8:00 PM"
/// flips to allowed within a quarter minute of expiry, cheap enough
/// that it's invisible in battery stats. Expiry is ALWAYS evaluated
/// against real timestamps at read time — this tick only refreshes UI,
/// it is never the authority.
final evaluationTickProvider = StreamProvider<void>((ref) {
  return Stream<void>.periodic(const Duration(seconds: 15));
});

/// Singleton settings row.
final ulimitSettingsProvider = StreamProvider<UlimitSetting>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.ulimitSettings).watchSingle();
});

/// Immersive-browsing toggle: true hides the floating nav pill entirely.
final hideNavBarProvider = StreamProvider<bool>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.ulimitSettings).watchSingle().map((s) => s.hideNavBar);
});

/// Bottom scroll inset for tab screens. With the floating pill visible
/// content needs ~110px of clearance so the last row never hides
/// behind it; in "Hide Nav Bar" immersive mode 16px is plenty.
const double navBarPillInset = 110;
const double navBarHiddenInset = 16;

class SettingsController {
  SettingsController(this._db);
  final AppDatabase _db;

  Future<void> setBiometricProtection(bool v) =>
      _update(UlimitSettingsCompanion(biometricProtection: Value(v)));
  Future<void> setHapticsEnabled(bool v) =>
      _update(UlimitSettingsCompanion(hapticsEnabled: Value(v)));

  /// Hides the floating nav pill entirely — immersive browsing mode.
  /// The scroll auto-hide still applies when this is false.
  Future<void> setHideNavBar(bool v) =>
      _update(UlimitSettingsCompanion(hideNavBar: Value(v)));
  Future<void> setPauseNotificationsDuringFocus(bool v) =>
      _update(UlimitSettingsCompanion(pauseNotificationsDuringFocus: Value(v)));
  Future<void> setDefaultFocusMinutes(int v) =>
      _update(UlimitSettingsCompanion(defaultFocusMinutes: Value(v)));
  Future<void> setVpnEnabled(bool v) =>
      _update(UlimitSettingsCompanion(vpnEnabled: Value(v)));

  /// Tile Appearance: 'system' | 'dark' | 'white'.
  Future<void> setThemeMode(String v) =>
      _update(UlimitSettingsCompanion(themeMode: Value(v)));

  /// Android system-level Focus Session indicator.
  Future<void> setFocusIndicatorEnabled(bool v) =>
      _update(UlimitSettingsCompanion(focusIndicatorEnabled: Value(v)));

  /// Marks the permissions onboarding as completed — the cold-start gate
  /// uses this to show a compact "re-enable after update" screen rather
  /// than the full onboarding wizard when Android resets privileged
  /// access after an app update.
  Future<void> setPermissionsOnboardingCompleted(bool v) =>
      _update(UlimitSettingsCompanion(permissionsOnboardingCompleted: Value(v)));

  /// When true, focus session tags render in their own color; when
  /// false, the monochrome chip style is used everywhere.
  Future<void> setColoredSessionTags(bool v) =>
      _update(UlimitSettingsCompanion(coloredSessionTags: Value(v)));

  Future<void> _update(UlimitSettingsCompanion c) async {
    await _ensureRow();
    await (_db.update(_db.ulimitSettings)..where((t) => t.id.equals(1))).write(c);
  }

  Future<void> _ensureRow() async {
    final rows = await _db.select(_db.ulimitSettings).get();
    if (rows.isEmpty) {
      await _db.into(_db.ulimitSettings).insert(UlimitSettingsCompanion.insert());
    }
  }
}

final settingsControllerProvider = Provider<SettingsController>(
  (ref) => SettingsController(ref.watch(databaseProvider)),
);

/// User-configurable daily screen-time budget (minutes).
final dailyBudgetProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.profile).watchSingleOrNull().map((row) => row?.dailyBudgetMinutes ?? 240);
});

/// Tile Appearance selection: 'system' | 'dark' | 'white'.
final themeModeProvider = StreamProvider<String>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.ulimitSettings).watchSingle().map((s) => s.themeMode);
});

/// Live today screen time in seconds: the persisted per-day total plus
/// the un-attributed elapsed time of whatever app is currently in front
/// (updated by usage events, ticked adaptively). Only consumers that
/// listen to this stream rebuild — the rest of Home does not.
///
/// Battery-aware cadence: 1s while the app is foreground (the counter
/// must feel live), 5s while it is backgrounded (keep-alive tabs still
/// hold the subscription; a 1s tick there is pure drain), and the timer
/// is cancelled entirely when nothing is listening.
final liveScreenTimeSecondsProvider = StreamProvider<int>((ref) {
  late final StreamController<int> controller;
  Timer? timer;

  int compute() {
    final base = ref.read(todayScreenTimeProvider).valueOrNull?.inSeconds ?? 0;
    final foreground = UsageTracker.liveForeground.value;
    // Ulimit's own foreground is not screen time (see
    // todayScreenTimeProvider); the pending window only counts while a
    // real app is in front.
    if (foreground == null || foreground.package == 'com.ulimit.app') return base;
    final pending = ((DateTime.now().millisecondsSinceEpoch - foreground.sinceMillis) / 1000)
        .floor()
        .clamp(0, 6 * 3600)
        .toInt();
    return base + pending;
  }

  // 1s foreground / 5s background throttling.
  bool _appBackgrounded = false;
  _AppLifecycleObserver? _lifecycleObserver;
  void _armTicker() {
    timer?.cancel();
    final cadence = _appBackgrounded
        ? const Duration(seconds: 5)
        : const Duration(seconds: 1);
    timer = Timer.periodic(cadence, (_) {
      if (!controller.isClosed) controller.add(compute());
    });
  }

  controller = StreamController<int>(
    onListen: () {
      controller.add(compute());
      _armTicker();
      // Pause the fast tick while backgrounded — keep-alive tabs keep
      // the subscription alive even when the app is not in view.
      _lifecycleObserver =
          _AppLifecycleObserver((state) {
        _appBackgrounded = state != AppLifecycleState.resumed;
        _armTicker();
      });
      WidgetsBinding.instance.addObserver(_lifecycleObserver!);
    },
    onCancel: () {
      timer?.cancel();
      final observer = _lifecycleObserver;
      if (observer != null) {
        WidgetsBinding.instance.removeObserver(observer);
        _lifecycleObserver = null;
      }
    },
  );
  ref.onDispose(() {
    timer?.cancel();
    final observer = _lifecycleObserver;
    if (observer != null) {
      WidgetsBinding.instance.removeObserver(observer);
      _lifecycleObserver = null;
    }
    controller.close();
  });
  return controller.stream;
});

/// Lifecycle observer shim so the provider can re-arm its tick cadence
/// without being a WidgetsBindingObserver itself.
class _AppLifecycleObserver extends WidgetsBindingObserver {
  _AppLifecycleObserver(this._onChange);
  final void Function(AppLifecycleState) _onChange;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _onChange(state);
}

Future<void> setDailyBudget(AppDatabase db, int minutes) async {
  final existing = await db.select(db.profile).get();
  if (existing.isEmpty) {
    await db.into(db.profile).insert(ProfileCompanion(dailyBudgetMinutes: Value(minutes)));
  } else {
    await (db.update(db.profile)..where((t) => t.id.equals(existing.first.id)))
        .write(ProfileCompanion(dailyBudgetMinutes: Value(minutes)));
  }
}

/// Today's total foreground time across all tracked apps, as a live
/// stream — Drift's .watch() pushes updates only when the underlying
/// rows change, so the ring on Home updates in real time without
/// polling. Ulimit's own foreground is excluded (like Digital
/// Wellbeing): time spent configuring the app is not "screen time".
final todayScreenTimeProvider = StreamProvider<Duration>((ref) {
  final db = ref.watch(databaseProvider);
  final startOfDay_ = startOfDay(DateTime.now());

  final query = db.select(db.appUsage)..where((t) => t.day.equals(startOfDay_));

  return query.watch().map(
        (rows) => Duration(
          seconds: rows
              .where((r) => r.packageName != 'com.ulimit.app')
              .fold(0, (sum, r) => sum + r.foregroundSeconds),
        ),
      );
});

/// Today's per-package usage — the input the restriction engine and the
/// Limits screen share, so a bar and the enforcement decision can never
/// disagree about "used". Ulimit's own foreground is excluded (its limit
/// is not part of the wellbeing budget).
final todayUsageByPackageProvider = StreamProvider<Map<String, int>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = startOfDay(DateTime.now());
  final query = db.select(db.appUsage)..where((t) => t.day.equals(today));
  return query.watch().map(
        (rows) => {
          for (final r in rows)
            if (r.packageName != 'com.ulimit.app') r.packageName: r.foregroundSeconds,
        },
      );
});

/// Debounced mirror of [todayUsageByPackageProvider] for UI consumers.
///
/// The raw usage stream emits on every tracked app switch (each
/// foreground upsert) — cheap for a number, but the restriction engine
/// re-evaluates ALL policy state in response, and on low-end hardware
/// that per-switch burst is the stutter. A limit crossing is
/// minute-granularity logic; 2s of coalescing is invisible: a burst of
/// 10 switches → ONE engine evaluation, not 10. The first emission
/// passes through immediately (cold start never waits), every later one
/// is coalesced.
final todayUsageByPackageDebouncedProvider =
    StreamProvider<Map<String, int>>((ref) {
  final raw = ref.watch(todayUsageByPackageProvider.stream);
  late final StreamController<Map<String, int>> controller;
  Timer? debounce;
  Map<String, int>? latest;
  var first = true;

  controller = StreamController<Map<String, int>>(
    onListen: () {
      final sub = raw.listen((usage) {
        latest = usage;
        if (first) {
          // Leading edge: the app must show truth immediately.
          first = false;
          debounce?.cancel();
          controller.add(usage);
          return;
        }
        // Trailing coalesce: restart the 2s quiet-window timer; emit
        // only when the stream has been still for 2 seconds.
        debounce?.cancel();
        debounce = Timer(const Duration(seconds: 2), () {
          if (!controller.isClosed && latest != null) controller.add(latest!);
        });
      });
      sub.onError((_) {});
      sub.onDone(() => controller.close());
      ref.onDispose(() {
        debounce?.cancel();
        controller.close();
      });
    },
    onCancel: () => debounce?.cancel(),
  );
  return controller.stream;
});

/// Last 7 days of total foreground time, oldest first — feeds Home's
/// weekly trend chart. One bucket pass instead of 7 separate day lookups.
final weeklyScreenTimeProvider = StreamProvider<List<Duration>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 6));

  final query = db.select(db.appUsage)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map(
        (rows) => bucketByDay(rows.map((r) => (r.day, r.foregroundSeconds)), start),
      );
});

/// Last 7 days of completed-focus-session time, oldest first. Falls
/// back to `plannedSeconds` for a session with no `endedAt` yet (in
/// progress) so an active session doesn't read as zero minutes.
final weeklyFocusTimeProvider = StreamProvider<List<Duration>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 6));

  final query = db.select(db.focusSessions)
    ..where((t) => t.completed.equals(true) & t.startedAt.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final entries = rows.map((r) {
      // Untimed sessions (plannedSeconds = -1) measure actual elapsed
      // time; a completed timed session measures start → end.
      final seconds = r.endedAt != null
          ? r.endedAt!.difference(r.startedAt).inSeconds
          : (r.plannedSeconds > 0 ? r.plannedSeconds : 0);
      return (r.startedAt, seconds);
    });
    return bucketByDay(entries, start);
  });
});

/// Count of focus sessions completed so far today — feeds both Home's
/// "N sessions" pill and Focus's session dot row.
final todaysCompletedSessionsProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = startOfDay(DateTime.now());
  final end = start.add(const Duration(days: 1));

  final query = db.select(db.focusSessions)
    ..where((t) =>
        t.completed.equals(true) & t.startedAt.isBiggerOrEqualValue(start) & t.startedAt.isSmallerThanValue(end));

  return query.watch().map((rows) => rows.length);
});

/// Turns a stream of (day, seconds) rows into a fixed 7-slot list
/// starting at [start], zero-filling any day with no rows.
List<Duration> bucketByDay(Iterable<(DateTime, int)> entries, DateTime start) {
  final byDay = <DateTime, int>{for (var i = 0; i <= 6; i++) startOfDay(start.add(Duration(days: i))): 0};
  for (final (day, seconds) in entries) {
    final d = startOfDay(day);
    byDay[d] = (byDay[d] ?? 0) + seconds;
  }
  final orderedDays = byDay.keys.toList()..sort();
  return [for (final d in orderedDays) Duration(seconds: byDay[d]!)];
}

/// One restriction group with today's live usage joined in. `used` is
/// the shared pool across members — the same number the engine checks.
class RestrictionGroupView {
  const RestrictionGroupView({
    required this.id,
    required this.name,
    required this.usedSeconds,
    required this.limitSeconds,
    required this.invincible,
    required this.packageNames,
  });

  final int id;
  final String name;
  final int usedSeconds;
  final int limitSeconds;
  final bool invincible;
  final List<String> packageNames;
}

final restrictionGroupsProvider = StreamProvider<List<RestrictionGroupView>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = startOfDay(DateTime.now());

  final query = db.customSelect(
    '''
    SELECT rg.id AS group_id, rg.name AS name, rg.daily_limit_seconds AS daily_limit_seconds,
           rg.invincible AS invincible, rga.package_name AS package_name,
           COALESCE(usage.foreground_seconds, 0) AS pkg_seconds
    FROM restriction_groups rg
    LEFT JOIN restriction_group_apps rga ON rga.group_id = rg.id
    LEFT JOIN app_usage usage ON usage.package_name = rga.package_name AND usage.day = ?
    ORDER BY rg.id
    ''',
    variables: [Variable.withDateTime(today)],
    readsFrom: {db.restrictionGroups, db.restrictionGroupApps, db.appUsage},
  );

  return query.watch().map((rows) {
    final byGroup = <int, _MutableGroup>{};
    final order = <int>[];

    for (final row in rows) {
      final id = row.read<int>('group_id');
      final group = byGroup.putIfAbsent(id, () {
        order.add(id);
        return _MutableGroup(
          name: row.read<String>('name'),
          limitSeconds: row.read<int>('daily_limit_seconds'),
          invincible: row.read<bool>('invincible'),
        );
      });

      final pkg = row.readNullable<String>('package_name');
      if (pkg != null) {
        group.packageNames.add(pkg);
        group.usedSeconds += row.read<int>('pkg_seconds');
      }
    }

    return [for (final id in order) byGroup[id]!.toView(id)];
  });
});

class _MutableGroup {
  _MutableGroup({required this.name, required this.limitSeconds, required this.invincible});
  final String name;
  final int limitSeconds;
  final bool invincible;
  int usedSeconds = 0;
  final List<String> packageNames = [];

  RestrictionGroupView toView(int id) => RestrictionGroupView(
        id: id,
        name: name,
        usedSeconds: usedSeconds,
        limitSeconds: limitSeconds,
        invincible: invincible,
        packageNames: packageNames,
      );
}

/// The single [BedtimeSchedule] row (singleton) — null until first edit.
final bedtimeScheduleProvider = StreamProvider<BedtimeScheduleData?>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.bedtimeSchedule)..limit(1);
  return query.watch().map((rows) => rows.isEmpty ? null : rows.first);
});

extension BedtimeScheduleActions on AppDatabase {
  Future<BedtimeScheduleData> _ensureBedtimeRow() async {
    final existing = await (select(bedtimeSchedule)..limit(1)).getSingleOrNull();
    if (existing != null) return existing;
    final id = await into(bedtimeSchedule).insert(
      BedtimeScheduleCompanion.insert(startTime: '22:30', endTime: '06:30'),
    );
    return (select(bedtimeSchedule)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> setBedtimeEnabled(bool value) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(enabled: Value(value)));
  }

  Future<void> setBedtimeTimes(String start, String end) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(
      startTime: Value(start),
      endTime: Value(end),
    ));
  }

  Future<void> setDndEnabled(bool value) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(dndEnabled: Value(value)));
  }

  Future<void> setPauseApps(bool value) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(pauseApps: Value(value)));
  }

  Future<void> setGrayscale(bool value) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(grayscale: Value(value)));
  }

  Future<void> setBedtimeInternet(bool value) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(blockInternet: Value(value)));
  }

  Future<void> setBedtimeApps(List<String> packages) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(
      selectedApps: Value(packages),
    ));
  }
}

/// Daily pickup counts for the last 7 days, oldest→newest.
final weeklyPickupsProvider = StreamProvider<List<int>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = startOfDay(DateTime.now().subtract(const Duration(days: 6)));

  final query = db.select(db.pickupsLog)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final byDay = {for (final r in rows) r.day: r.count};
    return List.generate(7, (i) {
      final day = start.add(Duration(days: i));
      return byDay[day] ?? 0;
    });
  });
});
