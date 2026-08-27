package com.ulimit.app

import io.flutter.plugin.common.EventChannel

/// Simple in-process bridge. UlimitAccessibilityService runs in the same
/// process as the Flutter engine (no `android:process` set in the
/// manifest), so a static sink reference is sufficient — this avoids
/// standing up a full plugin/AIDL layer for what's fundamentally a
/// same-process callback.
///
/// [sink] is null whenever Dart isn't listening (app not running, or
/// between hot restarts) — [emit] guards against that so the service
/// never crashes trying to push into a torn-down channel.
object UsageEventBridge {
    var sink: EventChannel.EventSink? = null

    fun emit(packageName: String, timestampMillis: Long) {
        sink?.success(
            mapOf(
                "package" to packageName,
                "timestamp" to timestampMillis
            )
        )
    }
}
