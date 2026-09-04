import 'package:flutter/services.dart';

/// One real event per foreground-app transition, pushed from
/// UlimitAccessibilityService.kt. This is the actual data source behind
/// every "usage" number in the app — nothing here is synthetic.
class ForegroundEvent {
  ForegroundEvent({required this.packageName, required this.timestampMillis});

  factory ForegroundEvent.fromMap(Map<dynamic, dynamic> map) => ForegroundEvent(
        packageName: map['package'] as String,
        timestampMillis: map['timestamp'] as int,
      );

  final String packageName;
  final int timestampMillis;
}

class UsageEventsChannel {
  UsageEventsChannel._();
  static const _events = EventChannel('com.ulimit.app/usage_events');

  static Stream<ForegroundEvent> get stream => _events
      .receiveBroadcastStream()
      .map((raw) => ForegroundEvent.fromMap(raw as Map<dynamic, dynamic>));
}

/// Sentinel "package" names used for signalling (never real packages).
class UlimitSentinel {
  UlimitSentinel._();

  /// Emitted by the accessibility service the instant it connects so the
  /// Dart side re-pushes the native policy snapshot (fresh restrictions
  /// even when the service was enabled outside the normal app flow).
  static const accessibilityReady = '__accessibility_ready__';

  /// Emitted when the accessibility service unbinds (user disabled it,
  /// or the OS reclaimed it). Lets Dart drop the stale live-foreground
  /// session instead of letting its pending counter grow forever.
  static const accessibilityDown = '__accessibility_down__';

  /// Emitted by the process-wide screen-state receiver in
  /// UlimitApplication when the screen turns off. Digital Wellbeing
  /// stops counting at screen-off (the framework pauses the resumed
  /// activity) — the accessibility layer gets no window event for that,
  /// so this sentinel is what closes the open usage session at the
  /// exact same moment DW would.
  static const screenOff = '__screen_off__';

  /// Screen back on — diagnostics-only marker (the next real window
  /// event after unlock resumes attribution naturally).
  static const screenOn = '__screen_on__';

  /// Emitted by the native feed-surface detector whenever a
  /// Reels/Shorts/For-You-style surface appears in a section-level
  /// doomscroll app. Full package name format:
  /// `__doom_open__:<package>` — one event = one "feed open".
  static const doomOpenPrefix = '__doom_open__:';
}
