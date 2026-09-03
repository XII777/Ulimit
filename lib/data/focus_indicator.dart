import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/native/enforcement_channel.dart';
import 'doomscroll_providers.dart';
import 'doomscroll_apps.dart';
import 'focus_providers.dart';
import 'providers.dart';
import 'usage_tracker.dart';

/// Keeps the Android system-level Focus Session indicator (foreground
/// service + ongoing notification with live chronometer and
/// Pause/Resume/End actions) in sync with the ONE focus-session state:
///
///   indicator enabled AND a session is running  → indicator exists
///   otherwise                                   → indicator removed
///
/// Runs in the app engine (watches the live DB streams) and is also
/// driven by the background engine after system-UI actions.
final focusIndicatorSyncProvider = Provider<FocusIndicatorSync>((ref) {
  final sync = FocusIndicatorSync(ref);
  ref.listen(activeFocusSessionProvider, (_, __) => sync.sync());
  ref.listen(focusIndicatorEnabledProvider, (_, __) => sync.sync());
  ref.listen(doomscrollTodayCountsProvider, (_, __) => sync.sync());
  // Live foreground transitions drive the doomscroll counting on the
  // notification chip: entering a feed app pushes its count to the chip,
  // leaving it restores the plain countdown text.
  ref.listen(liveForegroundProvider, (_, __) => sync.syncDoomscrollChip());
  return sync;
});

final focusIndicatorEnabledProvider = StreamProvider<bool>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.ulimitSettings).watchSingle().map((s) => s.focusIndicatorEnabled);
});

class FocusIndicatorSync {
  FocusIndicatorSync(this._ref);

  final Ref _ref;

  Future<void> sync() async {
    final enabled = _ref.read(focusIndicatorEnabledProvider).valueOrNull ?? true;
    final session = _ref.read(activeFocusSessionProvider).valueOrNull;

    if (!enabled || session == null) {
      // Removing when nothing is running is a safe no-op for native.
      await EnforcementChannel.stopFocusIndicator();
      return;
    }

    final live = _doomscrollLive();
    await EnforcementChannel.startFocusIndicator(
      label: session.label,
      startedAt: session.startedAt,
      endsAt: FocusClock.plannedEnd(session),
      paused: FocusClock.isPaused(session),
      doomPackage: live?.$1,
      doomCount: live?.$2 ?? 0,
    );
  }

  /// Live doomscroll counting on the notification chip: only pushes an
  /// update when the live foreground is one of the feed apps (entering
  /// it shows "N opens today · <app>", leaving restores the plain
  /// countdown). No-ops when no session is running.
  Future<void> syncDoomscrollChip() async {
    final enabled = _ref.read(focusIndicatorEnabledProvider).valueOrNull ?? true;
    final session = _ref.read(activeFocusSessionProvider).valueOrNull;
    if (!enabled || session == null) return;

    final live = _doomscrollLive();
    await EnforcementChannel.updateFocusNotification(
      label: session.label,
      endsAt: FocusClock.plannedEnd(session),
      paused: FocusClock.isPaused(session),
      doomPackage: live?.$1,
      doomCount: live?.$2 ?? 0,
    );
  }

  /// (package, today's opens) when the user is currently inside a
  /// doomscroll platform, else null.
  (String, int)? _doomscrollLive() {
    final foreground = _ref.read(liveForegroundProvider).valueOrNull;
    if (foreground == null) return null;
    if (doomscrollPlatformFor(foreground.package) == null) return null;
    final counts = _ref.read(doomscrollTodayCountsProvider).valueOrNull;
    return (foreground.package, counts?[foreground.package] ?? 0);
  }

  /// Called from the platform channel after a system-UI action so the
  /// Dart state, the enforcement snapshot and the indicator all move
  /// together through the ONE FocusController.
  Future<void> handleAction(String action) async {
    final controller = _ref.read(focusControllerProvider);
    switch (action) {
      case 'pause':
        await controller.pause();
        break;
      case 'resume':
        await controller.resume();
        break;
      case 'end':
        await controller.endEarly();
        break;
      default:
        return;
    }
    // The session stream emits on the DB write; sync() then starts,
    // updates (pause/resume) or removes (end) the indicator.
    await sync();
  }
}
