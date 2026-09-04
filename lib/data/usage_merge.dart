import 'db/app_database.dart';

/// How the two usage-accounting columns combine into the one number the
/// user sees everywhere (ring, charts, per-app stats, limits, engine).
///
/// `os_foreground_seconds` comes from UsageStatsManager's
/// `totalTimeInForeground` — the exact same aggregation Digital
/// Wellbeing displays. `foreground_seconds` comes from the accessibility
/// tracker's own gap attribution.
///
/// Rule: **OS wins whenever it has reported anything for that
/// (package, day)**; the tracker only fills the gap when the OS has
/// nothing (a session started seconds ago, or usage access is not
/// granted). Never `max()` — the tracker's gap attribution can
/// over-count (notification shade, app switcher, missed screen-off
/// edges), and letting it raise the total above the OS figure is exactly
/// the "our number is bigger than Digital Wellbeing" bug.
int mergedUsageSeconds({required int trackerSeconds, required int osSeconds}) {
  if (osSeconds > 0) return osSeconds;
  return trackerSeconds < 0 ? 0 : trackerSeconds;
}

/// The same rule applied to a live row read from the database.
extension AppUsageRowMerge on AppUsageData {
  /// The user-visible foreground seconds for this row.
  int get effectiveSeconds =>
      mergedUsageSeconds(trackerSeconds: foregroundSeconds, osSeconds: osForegroundSeconds);

  /// Same SQL expression as [mergedUsageSecondsUsageSql] — keep in sync.
  static const sqlAliasExpression =
      '(CASE WHEN COALESCE(usage.os_foreground_seconds, 0) > 0 '
      'THEN COALESCE(usage.os_foreground_seconds, 0) '
      'ELSE COALESCE(usage.foreground_seconds, 0) END)';
}

/// SQL fragment for raw customSelect joins on `app_usage usage` — the
/// merged per-row seconds under the same OS-wins rule. (Kept as a
/// top-level constant because extension statics can't be interpolated
/// into string literals cleanly at every call site.)
const String mergedUsageSecondsSql =
    '(CASE WHEN COALESCE(usage.os_foreground_seconds, 0) > 0 '
    'THEN COALESCE(usage.os_foreground_seconds, 0) '
    'ELSE COALESCE(usage.foreground_seconds, 0) END)';
