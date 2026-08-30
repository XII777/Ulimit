import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/native/enforcement_channel.dart';
import 'db/app_database.dart';
import 'focus_providers.dart';
import 'providers.dart';

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

    await EnforcementChannel.startFocusIndicator(
      label: session.label,
      startedAt: session.startedAt,
      endsAt: FocusClock.plannedEnd(session),
      paused: FocusClock.isPaused(session),
    );
  }

  /// Called from the platform channel after a system-UI action so the
  /// Dart state, the enforcement snapshot and the indicator all move
  /// together through the ONE FocusController.
  Future<void> handleAction(String action) async {
    final controller = _ref.read(focusControllerProvider);
    switch (action) {
      case 'pause':
        await controller.pause();
      case 'resume':
        await controller.resume();
      case 'end':
        await controller.endEarly();
      default:
        return;
    }
    // The session stream emits on the DB write; sync() then starts,
    // updates (pause/resume) or removes (end) the indicator.
    await sync();
  }
}
