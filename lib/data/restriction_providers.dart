import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/engine/restriction_engine.dart';
import '../core/diagnostics/diagnostics_log.dart';
import '../core/native/enforcement_channel.dart';
import 'db/app_database.dart';
import 'doomscroll_apps.dart';
import 'doomscroll_providers.dart';
import 'focus_providers.dart';
import 'providers.dart';
import 'website_providers.dart';

/// Popular browser packages, the targets of adult-content screen
/// scanning (the accessibility service reads their visible text — URL
/// bar + page — and automatically goes back when a blocked domain is
/// present, then backs the browser out whenever the adult filter is on).
const kBrowserPackages = <String>[
  'com.android.chrome',
  'com.chrome.beta',
  'com.chrome.dev',
  'com.android.browser',
  'com.brave.browser',
  'org.mozilla.firefox',
  'org.mozilla.firefox_beta',
  'org.mozilla.fenix',
  'com.microsoft.emmx',
  'com.microsoft.edge',
  'com.opera.browser',
  'com.opera.mini.native',
  'com.sec.android.app.sbrowser',
  'mark.via',
  'com.duckduckgo.mobile.android',
];

// ---------------------------------------------------------------------------
// App limits
// ---------------------------------------------------------------------------

/// Per-app daily limits joined with today's usage.
class AppLimitView {
  const AppLimitView({
    required this.packageName,
    required this.limitSeconds,
    required this.usedSeconds,
    required this.enabled,
  });

  final String packageName;
  final int limitSeconds;
  final int usedSeconds;
  final bool enabled;

  int get remainingSeconds => (limitSeconds - usedSeconds).clamp(0, limitSeconds);
}

final appLimitsProvider = StreamProvider<List<AppLimitView>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = startOfDay(DateTime.now());

  final query = db.customSelect(
    '''
    SELECT al.package_name AS package_name, al.daily_limit_seconds AS daily_limit_seconds,
           al.enabled AS enabled, COALESCE(usage.foreground_seconds, 0) AS used_seconds
    FROM app_limits al
    LEFT JOIN app_usage usage ON usage.package_name = al.package_name AND usage.day = ?
    ORDER BY used_seconds DESC
    ''',
    variables: [Variable.withDateTime(today)],
    readsFrom: {db.appLimits, db.appUsage},
  );

  return query.watch().map((rows) => [
        for (final row in rows)
          AppLimitView(
            packageName: row.read<String>('package_name'),
            limitSeconds: row.read<int>('daily_limit_seconds'),
            usedSeconds: row.read<int>('used_seconds'),
            enabled: row.read<bool>('enabled'),
          ),
      ]);
});

extension AppLimitsActions on AppDatabase {
  Future<void> setAppLimit(String packageName, Duration limit) async {
    await into(appLimits).insertOnConflictUpdate(AppLimitsCompanion.insert(
      packageName: packageName,
      dailyLimitSeconds: limit.inSeconds,
    ));
  }

  Future<void> removeAppLimit(String packageName) async {
    await (delete(appLimits)..where((t) => t.packageName.equals(packageName))).go();
  }

  Future<void> setAppLimitEnabled(String packageName, bool enabled) async {
    await (update(appLimits)..where((t) => t.packageName.equals(packageName)))
        .write(AppLimitsCompanion(enabled: Value(enabled)));
  }
}

// ---------------------------------------------------------------------------
// Manual restrictions (temporary + persistent)
// ---------------------------------------------------------------------------

/// All manual restriction rows (the engine filters expiry at evaluation
/// time — this provider intentionally shows the raw rows so the
/// Restrictions screen can render expired items as "ended").
final manualRestrictionsProvider = StreamProvider<List<AppRestriction>>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.appRestrictions)
    ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
  return query.watch();
});

/// Manual rules that are active right now — refreshed by the evaluation
/// tick so items expire out of "Active restrictions" lists promptly.
final activeRestrictionsProvider = Provider<List<AppRestriction>>((ref) {
  ref.watch(evaluationTickProvider);
  final all = ref.watch(manualRestrictionsProvider).valueOrNull ?? const [];
  final now = DateTime.now();
  return all
      .where((r) => r.enabled && (r.permanent || (r.expiresAt != null && r.expiresAt!.isAfter(now))))
      .toList();
});

/// Count of active manual restrictions — Home's "Restrictions" tile.
final activeRestrictionsCountProvider = Provider<int>((ref) {
  return ref.watch(activeRestrictionsProvider).length;
});

extension AppRestrictionsActions on AppDatabase {
  Future<void> blockApp({
    required String packageName,
    required Duration? duration,
    bool permanent = false,
    bool invincible = false,
  }) async {
    final now = DateTime.now();
    await into(appRestrictions).insert(AppRestrictionsCompanion.insert(
      packageName: packageName,
      createdAt: now,
      expiresAt: Value(permanent ? null : now.add(duration ?? Duration.zero)),
      permanent: Value(permanent),
      invincible: Value(invincible),
    ));
    // Enforcement sync: the manualRestrictions watch (kept alive by
    // enforcementSyncProvider) invalidates on this write and re-pushes
    // the native snapshot within ~250ms — no explicit push needed here,
    // and pushing directly would race ahead of the stream emission.
  }

  Future<void> removeRestriction(int id) async {
    await (delete(appRestrictions)..where((t) => t.id.equals(id))).go();
  }
}

// ---------------------------------------------------------------------------
// Internet blocks (VPN layer)
// ---------------------------------------------------------------------------

final internetBlocksProvider = StreamProvider<List<InternetBlock>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.internetBlocks)..where((t) => t.enabled.equals(true))).watch();
});

extension InternetBlocksActions on AppDatabase {
  Future<void> setInternetBlocked(String packageName, bool blocked) async {
    if (blocked) {
      await into(internetBlocks)
          .insertOnConflictUpdate(InternetBlocksCompanion.insert(packageName: packageName));
    } else {
      await (delete(internetBlocks)..where((t) => t.packageName.equals(packageName))).go();
    }
  }
}

// ---------------------------------------------------------------------------
// Restriction engine binding
// ---------------------------------------------------------------------------

/// Full engine evaluation, live. Combines manual rules, limits, groups,
/// focus and bedtime into per-package decisions using today's usage.
///
/// The evaluation tick re-resolves expiry without DB writes — expiry is
/// timestamp-based, so no periodic sweep is ever needed for correctness;
/// this only keeps the UI truthful.
final restrictionDecisionsProvider = Provider<Map<String, AppDecision>>((ref) {
  ref.watch(evaluationTickProvider);

  final manual = ref.watch(manualRestrictionsProvider).valueOrNull ?? const [];
  final usage = ref.watch(todayUsageByPackageDebouncedProvider).valueOrNull ?? const {};
  final limits = ref.watch(appLimitsProvider).valueOrNull ?? const [];
  final groups = ref.watch(restrictionGroupsProvider).valueOrNull ?? const [];
  final focus = ref.watch(activeFocusSessionProvider).valueOrNull;
  final bedtime = ref.watch(bedtimeScheduleProvider).valueOrNull;
  final internet = ref.watch(internetBlocksProvider).valueOrNull ?? const [];
  final doomRules = ref.watch(doomscrollRulesProvider).valueOrNull;
  final doomCounts = ref.watch(doomscrollTodayCountsProvider).valueOrNull;

  final limitMap = {
    for (final l in limits)
      if (l.enabled) l.packageName: l.limitSeconds,
  };

  final groupRules = [
    for (final g in groups)
      if (g.packageNames.isNotEmpty)
        GroupRule(limitSeconds: g.limitSeconds, packages: g.packageNames),
  ];

  final focusState = focus == null
      ? null
      : FocusState(
          blockedPackages: focus.blockedPackages,
          endsAt: focus.startedAt.add(
            FocusClock.isUntimed(focus)
                ? const Duration(days: 3650)
                : Duration(seconds: focus.plannedSeconds),
          ),
          blockInternet: focus.blockInternet,
        );

  // Feed-native platforms only — section-level ones (Reels/Shorts
  // surfaces) are handled by the accessibility detector, never by a
  // package block, so the app itself stays usable.
  final DoomscrollState? doomState;
  if (doomRules == null) {
    doomState = null; // streams not loaded — evaluate without the layer
  } else {
    final feedNative = [
      for (final r in doomRules)
        if (r.enabled && !isSectionLevelPlatform(r.packageName)) r
    ];
    doomState = feedNative.isEmpty
        ? null
        : DoomscrollState(openLimits: {
            for (final r in feedNative) r.packageName: r.dailyOpenLimit,
          });
  }

  BedtimeState? bedtimeState;
  if (bedtime != null && bedtime.enabled) {
    bedtimeState = BedtimeState(
      startMinutes: _minutesOf(bedtime.startTime),
      endMinutes: _minutesOf(bedtime.endTime),
      selectedApps: bedtime.selectedApps,
      pauseApps: bedtime.pauseApps,
      blockInternet: bedtime.blockInternet,
    );
  }

  final packages = <String>{
    for (final r in manual) r.packageName,
    ...limitMap.keys,
    ...groups.expand((g) => g.packageNames),
    ...focusState?.blockedPackages ?? const <String>[],
    ...bedtimeState?.selectedApps ?? const <String>[],
    ...internet.map((i) => i.packageName),
    if (doomState != null) ...doomState.openLimits.keys,
  };

  final input = EngineInput(
    now: DateTime.now(),
    manualRules: [
      for (final r in manual)
        if (r.enabled)
          ManualRule(
            packageName: r.packageName,
            permanent: r.permanent,
            expiresAt: r.expiresAt,
          ),
    ],
    usageTodaySeconds: usage,
    appLimits: limitMap,
    groups: groupRules,
    focus: focusState,
    bedtime: bedtimeState,
    internetBlocks: {for (final i in internet) i.packageName},
    doomscroll: doomState,
    doomscrollOpensToday: doomCounts ?? const {},
  );

  return resolveAll(input, packages);
});

int _minutesOf(String hhmm) {
  final parts = hhmm.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

/// Decision for a single package (convenience for detail screens).
AppDecision? decisionFor(Ref ref, String packageName) =>
    ref.watch(restrictionDecisionsProvider)[packageName];

// ---------------------------------------------------------------------------
// Native enforcement sync
// ---------------------------------------------------------------------------

/// Watches every policy source and mirrors the current state into the
/// native snapshot + domain filter file. Any change (DB write, expiry
/// tick, focus start/stop) produces a fresh push; the push is cheap and
/// idempotent, so correctness doesn't depend on catching every single
/// transition — only on re-running whenever inputs change.
///
/// keepAlive is load-bearing: this provider is only ever `ref.read()`
/// (never watched by the UI), and Riverpod 2 disposes unwatched
/// providers at the end of the frame. Without it, every policy listen
/// created in the constructor dies with it — a block added mid-session
/// NEVER reaches native, and blocking silently does nothing while the
/// UI still shows the restriction as active.
final enforcementSyncProvider = Provider<EnforcementSync>((ref) {
  ref.keepAlive();
  final sync = EnforcementSync(ref);

  // Re-evaluate on the tick too, so expiries propagate to native
  // without waiting for a DB write.
  ref.listen(evaluationTickProvider, (_, __) => sync.push());

  return sync;
});

class EnforcementSync {
  EnforcementSync(this._ref) {
    // Subscribe to every policy source; any emission schedules a push.
    for (final provider in [
      manualRestrictionsProvider,
      appLimitsProvider,
      restrictionGroupsProvider,
      activeFocusSessionProvider,
      bedtimeScheduleProvider,
      internetBlocksProvider,
      todayUsageByPackageProvider,
      ulimitSettingsProvider,
      // Feed-blocking config (doomscroll rules) lives in the snapshot —
      // the accessibility scan reads it per window event.
      doomscrollRulesProvider,
    ]) {
      _ref.listen(provider, (_, __) => _schedulePush());
    }
  }

  final Ref _ref;
  Timer? _debounce;
  DomainFilterSync? _domainSync;

  // Push bookkeeping — surfaced by Settings → Blocking diagnostics so a
  // broken sync chain is visible instead of silent.
  static String lastPushSummary = 'no push yet this session';
  static String? lastPushError;

  void _schedulePush() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), push);
  }

  Future<void> push() async {
    try {
      await _pushInternal();
      lastPushError = null;
    } catch (e) {
      lastPushError = e.toString();
      lastPushSummary = 'PUSH FAILED @ ${DateTime.now().toIso8601String()}';
      DiagnosticsLog.record('policy push FAILED: $e', tag: 'sync');
    }
  }

  Future<void> _pushInternal() async {
    final ref = _ref;
    // Never write an EMPTY snapshot over a full one: the headless engine
    // (the Focus-indicator foreground service) starts a second container
    // whose DB streams haven't resolved yet — at that moment every
    // valueOrNull is null and a push would ship `blockedNow: []`, wiping
    // native's restrictions until the next emission re-pushes. The
    // streams' own emissions (registered in the constructor) trigger a
    // fresh push the moment they load, so skipping here is safe.
    if (ref.read(manualRestrictionsProvider).valueOrNull == null ||
        ref.read(appLimitsProvider).valueOrNull == null) {
      lastPushSummary = 'skipped (streams not ready)';
      DiagnosticsLog.record('policy push skipped — streams not ready', tag: 'sync');
      return;
    }
    final manual = ref.read(manualRestrictionsProvider).valueOrNull ?? const [];
    final limits = ref.read(appLimitsProvider).valueOrNull ?? const [];
    final groups = ref.read(restrictionGroupsProvider).valueOrNull ?? const [];
    final focus = ref.read(activeFocusSessionProvider).valueOrNull;
    final bedtime = ref.read(bedtimeScheduleProvider).valueOrNull;
    final internet = ref.read(internetBlocksProvider).valueOrNull ?? const [];
    final categories = ref.read(blockListCategoriesProvider).valueOrNull ?? const [];
    // Feed-blocking budgets: package → daily feed-open allowance
    // (0 = block the feed outright). Consumed by the accessibility
    // layer's feed-surface detector — the APP itself is never blocked.
    final doomRules = ref.read(doomscrollRulesProvider).valueOrNull ?? const [];
    final now = DateTime.now();

    // The engine's own verdict, shipped to native as a flat fast path:
    // the AccessibilityService applies these first, so what the UI
    // shows as "blocked" and what Android enforces can never diverge.
    // Structural evaluation (limits accrued offline, expiry math)
    // remains as the fallback for state that changes while Ulimit is
    // closed.
    final decisions = ref.read(restrictionDecisionsProvider);
    final blockedCount = decisions.values.where((d) => d.appBlocked).length;
    lastPushSummary =
        'pushed ${now.toIso8601String()} · manual=${manual.length} '
        'limits=${limits.length} blockedNow=$blockedCount';
    DiagnosticsLog.record(
      'snapshot pushed: manual=${manual.length} limits=${limits.length} '
      'groups=${groups.length} focus=${focus != null ? "on" : "off"} '
      'blockedNow=$blockedCount feeds=${doomRules.where((r) => r.enabled).length}',
      tag: 'sync',
    );

    final snapshot = <String, dynamic>{
      'blockedSnapshotAtMillis': now.millisecondsSinceEpoch,
      'blockedNow': [
        for (final e in decisions.entries)
          if (e.value.appBlocked)
            {
              'package': e.key,
              'reason': e.value.reason?.label ?? 'Blocked',
              'untilMillis': e.value.until?.millisecondsSinceEpoch ?? 0,
            },
      ],
      'pushedAtMillis': now.millisecondsSinceEpoch,
      'manual': [
        for (final r in manual)
          if (r.enabled &&
              (r.permanent || (r.expiresAt != null && r.expiresAt!.isAfter(now))))
            {
              'package': r.packageName,
              'permanent': r.permanent,
              'untilMillis': r.expiresAt?.millisecondsSinceEpoch ?? 0,
            },
      ],
      'limits': {
        for (final l in limits)
          if (l.enabled) l.packageName: l.limitSeconds,
      },
      'groups': [
        for (final g in groups)
          if (g.packageNames.isNotEmpty && g.limitSeconds > 0)
            {'limitSeconds': g.limitSeconds, 'packages': g.packageNames},
      ],
      'focus': focus == null
          ? null
          : {
              'untilMillis': focus.startedAt
                  .add(FocusClock.isUntimed(focus)
                      ? const Duration(days: 3650)
                      : Duration(seconds: focus.plannedSeconds))
                  .millisecondsSinceEpoch,
              'packages': focus.blockedPackages,
              'pauseNotifications': focus.pauseNotifications,
              'blockInternet': focus.blockInternet,
              // Feed-only doomscroll blocking during this session.
              'blockDoomscroll': focus.blockDoomscroll,
            },
      'bedtime': bedtime == null || !bedtime.enabled
          ? null
          : {
              'startMinutes': _minutesOf(bedtime.startTime),
              'endMinutes': _minutesOf(bedtime.endTime),
              'pauseApps': bedtime.pauseApps,
              'blockInternet': bedtime.blockInternet,
              'grayscale': bedtime.grayscale,
              'packages': bedtime.selectedApps,
            },
      'internetBlocks': [for (final i in internet) i.packageName],
      // Feed-blocking config. FEED-NATIVE platforms go to the engine's
      // package block; section-level ones (Reels/Shorts surfaces) are
      // consumed by the accessibility feed-surface detector — the app
      // itself is never blocked there.
      'doomscrollFeeds': {
        for (final r in doomRules) if (r.enabled) r.packageName: r.dailyOpenLimit,
      },
      'doomscrollSectionPackages': [
        for (final r in doomRules)
          if (r.enabled && isSectionLevelPlatform(r.packageName)) r.packageName,
      ],
      // Accessibility-side adult gating: when the (locked) adult
      // block-list is enabled, the accessibility service blocks the
      // BROWSER apps themselves — belt and braces alongside the VPN's
      // domain filter. The list is the popular-browser catalog; the
      // adult flag comes from the enabled block-list categories.
      'adultFilterEnabled': categories.any((c) => c.template.id == 'adult' && c.enabled),
      'browserPackages': kBrowserPackages,
    };

    await EnforcementChannel.pushSnapshot(snapshot);
    // A count limit can be crossed mid-scroll — re-evaluate whatever is
    // foreground right now so the block bites instantly, not on the
    // next app switch.
    await EnforcementChannel.reevaluateForeground();
    await _syncDomains(ref);
  }

  Future<void> _syncDomains(Ref ref) async {
    final custom = ref.read(customWebsiteRulesProvider).valueOrNull ?? const [];
    final categories = ref.read(blockListCategoriesProvider).valueOrNull ?? const [];
    final enabledCategories = <String>{
      for (final c in categories)
        if (c.downloaded && c.enabled) c.template.id,
    };

    if (enabledCategories.isEmpty) {
      // Only custom rules — stream them straight into the filter file.
      final domains = <String>{for (final r in custom) if (r.enabled) r.domain};
      _domainSync ??= await DomainFilterSync.create();
      await _domainSync!.sync(domains);
      return;
    }

    // With whole categories enabled the set can be 100k+ domains; pull
    // only enabled ones for the filter file.
    final db = ref.read(databaseProvider);
    final domains = <String>{
      for (final r in custom)
        if (r.enabled) r.domain,
    };
    final rows = await (db.select(db.websiteRules)
          ..where((t) => t.enabled.equals(true) & t.category.isIn(enabledCategories)))
        .get();
    domains.addAll(rows.map((r) => r.domain));
    _domainSync ??= await DomainFilterSync.create();
    await _domainSync!.sync(domains);
  }
}
