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

  /// Emitted by the native feed-surface detector whenever a
  /// Reels/Shorts/For-You-style surface appears in a section-level
  /// doomscroll app. Full package name format:
  /// `__doom_open__:<package>` — one event = one "feed open".
  static const doomOpenPrefix = '__doom_open__:';
}
