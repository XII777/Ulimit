package com.ulimit.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter

/**
 * Process-wide screen on/off forwarder.
 *
 * Digital Wellbeing stops counting screen time the moment the screen
 * goes off — the framework emits an ACTIVITY_PAUSED for the resumed
 * activity. The accessibility layer receives NO window event for
 * screen-off, so without this bridge our tracker would keep attributing
 * the whole locked period to whatever app was in front (the classic
 * "our number is bigger than DW" source). The Application registers the
 * receiver once at process start; events flow through the same
 * [UsageEventBridge] sentinel channel Dart already listens on.
 */
object ScreenStateForwarder {

    private var registered = false

    fun register(context: Context) {
        if (registered) return
        registered = true

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }

        context.applicationContext.registerReceiver(object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                val now = System.currentTimeMillis()
                when (intent.action) {
                    Intent.ACTION_SCREEN_OFF -> {
                        UsageEventBridge.emit(UsageEventBridge.SCREEN_OFF, now)
                        DiagnosticsMarkers.lastScreenOffAt = now
                        // Close the native-side usage session too (the
                        // accessibility tracker must not count the
                        // locked period any more than Dart's does).
                        UlimitAccessibilityService.instance?.closeUsageSession()
                    }
                    Intent.ACTION_SCREEN_ON ->
                        UsageEventBridge.emit(UsageEventBridge.SCREEN_ON, now)
                    // Unlock after secure lock — nothing to attribute (the
                    // screen-on event already resumed the clock), but it
                    // confirms the receiver chain is alive: diagnostics.
                    Intent.ACTION_USER_PRESENT ->
                        DiagnosticsMarkers.lastUnlockAt = now
                }
            }
        }, filter)
    }
}

/// Cheap diagnostics breadcrumbs readable from the permissions channel —
/// the report can show whether the screen bridge is actually firing.
object DiagnosticsMarkers {
    @Volatile var lastScreenOffAt: Long = 0
    @Volatile var lastUnlockAt: Long = 0
    @Volatile var lastAccessibilityEventAt: Long = 0

    // Doomscroll feed-detector breadcrumbs — the copyable doom report
    // answers "is the detector even seeing events, is it matching
    // markers, is it ejecting" without a debugger.
    @Volatile var scrollEventsSeen: Int = 0
    @Volatile var lastScrollEventAt: Long = 0
    @Volatile var feedScans: Int = 0
    @Volatile var lastFeedScanAt: Long = 0
    @Volatile var lastFeedScanPkg: String = ""
    @Volatile var feedSurfaceHits: Int = 0
    @Volatile var lastFeedSurfaceHitAt: Long = 0
    @Volatile var feedEjects: Int = 0
    @Volatile var lastFeedEjectAt: Long = 0
    @Volatile var lastFeedEjectPkg: String = ""
    @Volatile var doomOpens: Int = 0
    @Volatile var lastDoomOpenAt: Long = 0
    @Volatile var lastDoomOpenPkg: String = ""
    @Volatile var gapDiscards: Int = 0
}
