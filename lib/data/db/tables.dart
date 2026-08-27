import 'package:drift/drift.dart';

/// One local profile row (singleton — no accounts). Display name, photo
/// path, and theme preference for the share card / settings.
class Profile extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get displayName => text().withDefault(const Constant('You'))();
  TextColumn get photoPath => text().nullable()();
  TextColumn get themeId => text().withDefault(const Constant('violet'))();
  // Daily screen-time budget in minutes, used by the Home ring and the
  // score formula's screen-time component. Configurable in Settings;
  // defaults to 4h for a fresh install so the ring has something
  // meaningful to show before the user sets their own number.
  IntColumn get dailyBudgetMinutes => integer().withDefault(const Constant(240))();
}

class FocusSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get label => text()(); // "Deep Work", "Study"...
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get plannedSeconds => integer()();
  BoolColumn get invincible => boolean().withDefault(const Constant(false))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
}

/// One row per tracked package per day. Aggregated in-memory for
/// weekly/monthly views rather than maintaining separate rollup tables —
/// at this data volume (a few hundred rows/month/device) a SUM query is
/// cheaper than the bookkeeping a materialized rollup would need.
class AppUsage extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get packageName => text()();
  DateTimeColumn get day => dateTime()(); // truncated to midnight
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

class BlockedApps extends Table {
  TextColumn get packageName => text()();
  TextColumn get scheduleStart => text().nullable()(); // "HH:mm" or null = all day
  TextColumn get scheduleEnd => text().nullable()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {packageName};
}

class BedtimeSchedule extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get startTime => text()(); // "22:30"
  TextColumn get endTime => text()(); // "06:30"
  BoolColumn get dndEnabled => boolean().withDefault(const Constant(true))();
  BoolColumn get pauseApps => boolean().withDefault(const Constant(true))();
  BoolColumn get grayscale => boolean().withDefault(const Constant(false))();
}

/// Daily snapshot of the Limit score components, so the score is
/// recomputable/auditable rather than a single mutated integer —
/// important once "decay" or recalculation logic changes later.
class ScoreLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get day => dateTime()();
  RealColumn get screenTimeComponent => real()();
  RealColumn get focusConsistencyComponent => real()();
  RealColumn get streakComponent => real()();
  RealColumn get limitsKeptComponent => real()();
  IntColumn get totalScore => integer()();
}

class EmergencyUnlocks extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get usedAt => dateTime()();
  TextColumn get packageName => text()();
  IntColumn get grantedSeconds => integer()();
}

/// One row per day. Incremented every time the AccessibilityService
/// reports a foreground-app transition — this is what "Pickups / day"
/// on Home actually measures. Approximate by nature (a true "unlock"
/// signal would need ACTION_USER_PRESENT from a separate BroadcastReceiver,
/// which is a reasonable v2 addition), but every foreground switch is a
/// real, on-device event, not a guess.
class PickupsLog extends Table {
  DateTimeColumn get day => dateTime()(); // truncated to midnight

  IntColumn get count => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {day};
}
