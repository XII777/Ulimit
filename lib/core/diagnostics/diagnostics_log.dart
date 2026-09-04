import 'package:flutter/foundation.dart';

/// In-memory rolling log of system events — the "what happened, when,
/// did it work" record surfaced by the Diagnostics screen.
///
/// Records the enforcement chain end-to-end: policy pushes (and their
/// failures), feed-surface detections, rule changes, indicator syncs.
/// Deliberately a static ring buffer: every producer is deep in the
/// data layer where a Riverpod ref is not available, and the log must
/// survive provider rebuilds anyway.
class DiagnosticsLog {
  DiagnosticsLog._();

  static const _maxEntries = 300;

  static final List<DiagnosticsEntry> _entries = [];

  /// Bumped on every append so listeners (the Diagnostics screen) can
  /// rebuild cheaply without holding the list itself.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static void record(String event, {String tag = 'system'}) {
    _entries.add(DiagnosticsEntry(
      at: DateTime.now(),
      tag: tag,
      event: event,
    ));
    while (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    revision.value++;
  }

  /// Newest first.
  static List<DiagnosticsEntry> get entries =>
      List.unmodifiable(_entries.reversed);

  static bool get isEmpty => _entries.isEmpty;
}

class DiagnosticsEntry {
  const DiagnosticsEntry({
    required this.at,
    required this.tag,
    required this.event,
  });

  final DateTime at;

  /// Short source label shown as a prefix: 'sync', 'feed', 'indicator',
  /// 'rules', 'system'.
  final String tag;
  final String event;

  @override
  String toString() => '[${tag.toUpperCase()}] $event';
}
