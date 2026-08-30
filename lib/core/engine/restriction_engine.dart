import 'dart:math' as math;

/// The single decision authority for "should package X (or domain Y) be
/// accessible right now?"
///
/// Every feature (manual blocking, daily limits, restriction groups,
/// focus, bedtime, internet blocking) feeds evidence into one resolver
/// here instead of each feature implementing its own enforcement. The
/// conflict rule is fixed: **the most restrictive active policy wins** —
/// policies are OR'd together for blocking, and the returned `until`
/// is the earliest active expiry so the UI can always show a truthful
/// "unblocks at".
///
/// Pure functions only: no I/O, no clock access beyond the [now] passed
/// in. That makes the entire policy layer unit-testable, including
/// midnight rollover, expiry edges, and overnight bedtime windows.

enum BlockReason {
  manual('Blocked'),
  dailyLimit('Daily limit reached'),
  groupLimit('Group limit reached'),
  focus('Focus session'),
  bedtime('Bedtime');

  const BlockReason(this.label);
  final String label;
}

/// Result of resolving one package.
class AppDecision {
  const AppDecision({
    required this.appBlocked,
    required this.internetBlocked,
    this.reason,
    this.until,
  });

  final bool appBlocked;
  final bool internetBlocked;

  /// Which policy is blocking, if any. When multiple are active the
  /// earliest-expiring one is reported so "unblocks at" is truthful.
  final BlockReason? reason;

  /// When access resumes. Null means indefinite (permanent block).
  final DateTime? until;

  static const allowed = AppDecision(appBlocked: false, internetBlocked: false);
}

/// An active (not-yet-expired) manual restriction row.
class ManualRule {
  const ManualRule({
    required this.packageName,
    required this.permanent,
    this.expiresAt,
  });

  final String packageName;
  final bool permanent;
  final DateTime? expiresAt;
}

class GroupRule {
  const GroupRule({
    required this.limitSeconds,
    required this.packages,
  });

  final int limitSeconds;
  final List<String> packages;
}

class FocusState {
  const FocusState({
    required this.blockedPackages,
    required this.endsAt,
    this.blockInternet = false,
  });

  final List<String> blockedPackages;
  final DateTime endsAt;
  final bool blockInternet;

  bool get active => endsAt.isAfter(DateTime.now());
}

class BedtimeState {
  const BedtimeState({
    required this.startMinutes,
    required this.endMinutes,
    required this.selectedApps,
    this.pauseApps = true,
    this.blockInternet = false,
  });

  /// Minutes since local midnight. May wrap past 24h (e.g. 23:00 = 1380).
  final int startMinutes;
  final int endMinutes;
  final List<String> selectedApps;
  final bool pauseApps;
  final bool blockInternet;
}

class EngineInput {
  const EngineInput({
    required this.now,
    required this.manualRules,
    required this.usageTodaySeconds,
    required this.appLimits,
    required this.groups,
    this.focus,
    this.bedtime,
    this.internetBlocks = const <String>{},
  });

  final DateTime now;

  /// Already filtered to enabled + not-expired rows by the caller? No —
  /// the engine owns expiry so callers can't disagree about it.
  final List<ManualRule> manualRules;

  final Map<String, int> usageTodaySeconds;
  final Map<String, int> appLimits; // seconds allowed per day
  final List<GroupRule> groups;
  final FocusState? focus;
  final BedtimeState? bedtime;

  /// Packages the user explicitly blocked internet for (VPN layer).
  final Set<String> internetBlocks;
}

/// True when [minutes] falls inside the [start, end) minute-of-day
/// window. Supports overnight windows (start > end, e.g. 23:00→06:30)
/// by treating them as [start, 24h) ∪ [0, end).
bool isMinuteInWindow(int minutes, int start, int end) {
  final m = minutes % (24 * 60);
  if (start == end) return false; // zero-length window is never active
  if (start < end) return m >= start && m < end;
  return m >= start || m < end;
}

/// When the window containing [now] ends. Handles overnight wrap:
/// if [now] is in the "after midnight" half of a 23:00→06:30 window,
/// the end is today at end-minutes; if in the "before midnight" half,
/// the end is tomorrow.
DateTime windowEndFor(DateTime now, int start, int end) {
  final minutesNow = now.hour * 60 + now.minute;
  final midnight = DateTime(now.year, now.month, now.day);
  DateTime atMinutes(DateTime day) => day.add(Duration(minutes: end));

  if (start < end) {
    return atMinutes(midnight);
  }
  // Overnight window.
  if (minutesNow >= start) {
    return atMinutes(midnight.add(const Duration(days: 1)));
  }
  return atMinutes(midnight);
}

/// End of [now]'s local day — when daily limits reset.
DateTime endOfDayFor(DateTime now) {
  final d = DateTime(now.year, now.month, now.day);
  return d.add(const Duration(days: 1));
}

AppDecision resolvePackage(EngineInput input, String packageName) {
  final candidates = <BlockReason, DateTime?>{};

  // 1. Manual restrictions — engine owns expiry evaluation.
  for (final rule in input.manualRules) {
    if (rule.packageName != packageName) continue;
    if (rule.permanent) {
      candidates.putIfAbsent(BlockReason.manual, () => null);
    } else if (rule.expiresAt != null && rule.expiresAt!.isAfter(input.now)) {
      candidates.update(BlockReason.manual, (v) => v, ifAbsent: () => rule.expiresAt);
    }
  }

  // 2. Per-app daily limit — usage derived from today's AppUsage.
  final limit = input.appLimits[packageName];
  if (limit != null && limit > 0 && (input.usageTodaySeconds[packageName] ?? 0) >= limit) {
    candidates[BlockReason.dailyLimit] = endOfDayFor(input.now);
  }

  // 3. Group limits — shared pool across all member packages.
  for (final group in input.groups) {
    if (group.limitSeconds <= 0) continue;
    if (!group.packages.contains(packageName)) continue;
    var used = 0;
    for (final pkg in group.packages) {
      used += input.usageTodaySeconds[pkg] ?? 0;
    }
    if (used >= group.limitSeconds) {
      candidates[BlockReason.groupLimit] = endOfDayFor(input.now);
      break;
    }
  }

  // 4. Focus session.
  final focus = input.focus;
  if (focus != null && focus.endsAt.isAfter(input.now) && focus.blockedPackages.contains(packageName)) {
    candidates[BlockReason.focus] = focus.endsAt;
  }

  // 5. Bedtime window.
  final bedtime = input.bedtime;
  if (bedtime != null && bedtime.pauseApps) {
    final minutesNow = input.now.hour * 60 + input.now.minute;
    if (isMinuteInWindow(minutesNow, bedtime.startMinutes, bedtime.endMinutes) &&
        bedtime.selectedApps.contains(packageName)) {
      candidates[BlockReason.bedtime] =
          windowEndFor(input.now, bedtime.startMinutes, bedtime.endMinutes);
    }
  }

  if (candidates.isEmpty) {
    return AppDecision(
      appBlocked: false,
      // Explicit internet block still applies even when the app itself
      // is allowed (e.g. WhatsApp usable but data-restricted).
      internetBlocked: input.internetBlocks.contains(packageName),
    );
  }

  // Most restrictive wins; report the earliest-expiring active policy.
  DateTime? earliest;
  BlockReason? earliestReason;
  var indefinite = false;
  candidates.forEach((reason, until) {
    if (until == null) {
      indefinite = true;
      earliestReason ??= reason;
      return;
    }
    if (earliest == null || until.isBefore(earliest!)) {
      earliest = until;
      earliestReason = reason;
    }
  });

  return AppDecision(
    appBlocked: true,
    // A blocked app is also data-blocked: otherwise the block could be
    // trivially circumvented through the app's web version. Internet
    // ends at the same instant as the app block.
    internetBlocked: true,
    reason: indefinite ? earliestReason ?? candidates.keys.first : earliestReason,
    until: indefinite ? null : earliest,
  );
}

/// All decisions for a snapshot evaluation, keyed by package name.
Map<String, AppDecision> resolveAll(EngineInput input, Iterable<String> packages) {
  return {for (final p in packages) p: resolvePackage(input, p)};
}

/// Returns only manual rules that are currently active — used by both
/// the engine and UI lists so "active restrictions" always agrees with
/// what enforcement actually does.
List<ManualRule> activeManualRules(List<ManualRule> rules, DateTime now) {
  return rules
      .where((r) => r.permanent || (r.expiresAt != null && r.expiresAt!.isAfter(now)))
      .toList(growable: false);
}

/// Formats a clock duration "24:18" / "1:04:09" — the timer display
/// format used by the focus screen. Kept beside the engine because it
/// encodes the same "truthful remaining time" contract.
String formatClock(Duration remaining) {
  final clamped = remaining.isNegative ? Duration.zero : remaining;
  final h = clamped.inHours;
  final m = clamped.inMinutes % 60;
  final s = clamped.inSeconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:$mm:$ss';
  return '$mm:$ss';
}

/// Human duration with seconds when available — "2h 18m 43s", "48m 21s",
/// "42s". Used for Home metric counters where precision matters.
String formatDurationHMS(Duration d) {
  final clamped = d.isNegative ? Duration.zero : d;
  final h = clamped.inHours;
  final m = clamped.inMinutes % 60;
  final sec = clamped.inSeconds % 60;
  if (h > 0) return '${h}h ${m}m ${sec}s';
  if (m > 0) return '${m}m ${sec}s';
  return '${sec}s';
}

/// Human duration "4h 18m" / "36m" — used across dashboards.
String formatDurationShort(Duration d) {
  final clamped = d.isNegative ? Duration.zero : d;
  final h = clamped.inHours;
  final m = clamped.inMinutes % 60;
  if (h <= 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

/// Neutral-utility helper for progress bars: 0..1, never negative,
/// never NaN even with a zero budget.
double ratioOf({required int used, required int limit}) {
  if (limit <= 0) return 0;
  return (used / limit).clamp(0.0, 1.0);
}

/// Re-export so engine consumers don't need dart:math.
int minInt(int a, int b) => math.min(a, b);
