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
