import 'package:drift/drift.dart';

import 'converters.dart';

/// One local profile row (singleton — no accounts). Display name and
/// daily screen-time budget live here.
class Profile extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get displayName => text().withDefault(const Constant('You'))();
  TextColumn get photoPath => text().nullable()();
  // Daily screen-time budget in minutes, used by the Home ring.
  // Defaults to 4h for a fresh install so the ring has something
  // meaningful to show before the user sets their own number.
  IntColumn get dailyBudgetMinutes => integer().withDefault(const Constant(240))();
}

/// One focus session. A running session is simply one with `endedAt`
/// still null; the restriction engine reads the newest such row.
class FocusSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get label => text()(); // "Deep Work", "Study"...
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get plannedSeconds => integer()();
  BoolColumn get invincible => boolean().withDefault(const Constant(false))();

  // Focus policy — which enforcement policies this session activates.
  // Apps chosen in the start flow, stored per session so enforcement
  // survives process death (the engine re-derives everything from DB).
  TextColumn get blockedPackages => text()
      .map( StringListConverter())
      .withDefault(const Constant('[]'))();
  BoolColumn get pauseNotifications => boolean().withDefault(const Constant(true))();
  BoolColumn get blockInternet => boolean().withDefault(const Constant(false))();
  BoolColumn get blockWebsites => boolean().withDefault(const Constant(false))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();

  // Pause support: pausedAt is the timestamp the session was paused
  // (null = running); accumulatedPausedSeconds is the total time the
  // session has spent paused. Elapsed focus time is
  // now - startedAt - accumulatedPausedSeconds (frozen while paused).
  DateTimeColumn get pausedAt => dateTime().nullable()();
  IntColumn get accumulatedPausedSeconds => integer().withDefault(const Constant(0))();
}

/// User-created focus session tags ("Deep Work", "Study", ...). The
/// Focus screen shows the built-in labels plus these rows; each tag has
/// a color so a session reads as a colored chip everywhere it appears.
class FocusTags extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  // ARGB color value (0xFFRRGGBB) — stored so the chip color survives
  // across theme changes without a lookup table.
  IntColumn get colorValue => integer()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// One row per tracked package per day. Aggregated in-memory for
/// weekly/monthly views rather than maintaining separate rollup tables —
/// at this data volume (a few hundred rows/month/device) a SUM query is
/// cheaper than the bookkeeping a materialized rollup would need.
class AppUsage extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get packageName => text()();
  DateTimeColumn get day => dateTime()(); // truncated to midnight local
  IntColumn get foregroundSeconds => integer().withDefault(const Constant(0))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {packageName, day}
      ];
}

class RestrictionGroups extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get dailyLimitSeconds => integer()();
  BoolColumn get invincible => boolean().withDefault(const Constant(false))();
}

class RestrictionGroupApps extends Table {
  IntColumn get groupId => integer().references(RestrictionGroups, #id)();
  TextColumn get packageName => text()();

  @override
  Set<Column> get primaryKey => {groupId, packageName};
}

/// Per-app daily allowance. `usedTime` is never stored here — it's
/// always derived from [AppUsage] for today, so the number on screen and
/// the number the engine enforces can never disagree.
class AppLimits extends Table {
  TextColumn get packageName => text()();
  IntColumn get dailyLimitSeconds => integer()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {packageName};
}

/// A manual restriction with a real expiration timestamp. This is the
/// superset that replaces the old schedule-string blocks:
///  - temporary block  → expiresAt set
///  - persistent block  → permanent = true (expiresAt null)
///  - invincible block  → removing it requires biometric auth
class AppRestrictions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get packageName => text()();
  DateTimeColumn get createdAt => dateTime()();
  // Null = no expiry (only valid alongside permanent=true).
  DateTimeColumn get expiresAt => dateTime().nullable()();
  BoolColumn get permanent => boolean().withDefault(const Constant(false))();
  BoolColumn get invincible => boolean().withDefault(const Constant(false))();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
}

/// Per-app internet blocking (enforced by the local VPN's per-app
/// routing). Separate from [AppRestrictions] because the two are
/// enforced by different layers with different lifetimes.
class InternetBlocks extends Table {
  TextColumn get packageName => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {packageName};
}

class BedtimeSchedule extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get startTime => text()(); // "22:30"
  TextColumn get endTime => text()(); // "06:30"
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();
  BoolColumn get dndEnabled => boolean().withDefault(const Constant(true))();
  BoolColumn get pauseApps => boolean().withDefault(const Constant(true))();
  BoolColumn get blockInternet => boolean().withDefault(const Constant(false))();
  BoolColumn get grayscale => boolean().withDefault(const Constant(false))();
  TextColumn get selectedApps => text()
      .map( StringListConverter())
      .withDefault(const Constant('[]'))();
}

/// One website rule — either a user-added domain (`custom`) or a domain
/// imported from a block-list category (`<category-id>`). Per-domain
/// `enabled` is the user's granular toggle; a disabled row stays in the
/// DB so the toggle survives list updates.
class WebsiteRules extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get domain => text()();
  TextColumn get category => text().withDefault(const Constant('custom'))();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {domain, category}
      ];
}

/// Per-category state for the downloadable block lists (StevenBlack/
/// hosts). The catalog itself (titles/URLs/descriptions) is
/// static Dart; this table records what the user has downloaded and
/// whether the category's filter is on. `locked` is the one-way flag:
/// the Adult category cannot be turned off after being turned on.
class BlockListCategories extends Table {
  TextColumn get id => text()();
  BoolColumn get downloaded => boolean().withDefault(const Constant(false))();
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();
  BoolColumn get locked => boolean().withDefault(const Constant(false))();
  DateTimeColumn get downloadedAt => dateTime().nullable()();
  IntColumn get siteCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Singleton settings row. Anything the engine or enforcement layer
/// reads belongs here (or in a dedicated table) — never in shared_prefs
/// only, so Flutter and native always agree on the same source of truth.
class UlimitSettings extends Table {
  IntColumn get id => integer().autoIncrement()();
  // Require biometric/device credential before restrictions can be
  // changed or removed (Invincible Mode's core behavior).
  BoolColumn get biometricProtection => boolean().withDefault(const Constant(false))();
  BoolColumn get hapticsEnabled => boolean().withDefault(const Constant(true))();

  // Hide the floating nav pill entirely (immersive browsing): when true
  // the NavShell renders no bottom navigation — the pill auto-hide on
  // scroll still applies when false.
  BoolColumn get hideNavBar => boolean().withDefault(const Constant(false))();
  BoolColumn get pauseNotificationsDuringFocus => boolean().withDefault(const Constant(true))();
  IntColumn get defaultFocusMinutes => integer().withDefault(const Constant(25))();
  // Desired VPN state — the VPN reconnects to match this after reboot.
  BoolColumn get vpnEnabled => boolean().withDefault(const Constant(false))();
  // Tile Appearance: 'system' | 'dark' | 'white' — AMOLED dark theme,
  // monochrome white theme, or follow the Android system setting.
  TextColumn get themeMode => text().withDefault(const Constant('system'))();
  // Android system-level Focus Session indicator (foreground service +
  // ongoing notification with live timer and Pause/End controls).
  BoolColumn get focusIndicatorEnabled => boolean().withDefault(const Constant(true))();

  // Legacy: the Rolling Number Display setting was removed from the UI
  // (replaced by the on-demand fullscreen focus view). The column stays
  // so no schema migration is needed; nothing reads it anymore.
  BoolColumn get rollingNumberMode => boolean().withDefault(const Constant(false))();

  // True once the user completed the permissions onboarding step. Lets
  // the cold-start gate tell a first launch from a post-update reset:
  // Android re-claims accessibility/notification-listener access after
  // every app update, so existing users get a compact re-enable screen
  // instead of the full onboarding wizard again.
  BoolColumn get permissionsOnboardingCompleted => boolean().withDefault(const Constant(false))();

  // When true, focus session tags render with their own color; when
  // false, the design system's monochrome chips are used everywhere.
  BoolColumn get coloredSessionTags => boolean().withDefault(const Constant(false))();
}

/// One row per day. Incremented every time the AccessibilityService
/// reports a foreground-app transition — this is what "Pickups / day"
/// on Home actually measures.
class PickupsLog extends Table {
  DateTimeColumn get day => dateTime()(); // truncated to midnight

  IntColumn get count => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {day};
}
