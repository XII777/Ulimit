package com.ulimit.app

import android.app.Service.USAGE_STATS_SERVICE
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Detects which app is in the foreground and fires [onNewAppLaunched].
 *
 * Faithful port of Mindful's `LaunchTrackingManager`:
 *  - polls the OS UsageEvents stream every [TIMER_RATE_MILLIS] on a
 *    dedicated executor, maintaining the `activeApps` set from
 *    ACTIVITY_RESUMED (add) / ACTIVITY_PAUSED / ACTIVITY_STOPPED (remove);
 *    its first element is the current foreground app,
 *  - fires at most once per app change (deduped via [lastLaunchedApp]),
 *  - pauses the poll while the screen is off/locked, resumes on unlock,
 *  - receives fast-path launches from the accessibility service via
 *    [invokeNewAppLaunched] — the same role Mindful's accessibility-
 *    service broadcast plays, but as a direct callback (the broadcast
 *    adds a failure point without adding logic).
 */
class LaunchTrackingManager(
    private val context: Context,
    private val onNewAppLaunched: (String) -> Unit,
) {
    companion object {
        private const val TAG = "Ulimit.LaunchTracking"
        private const val TIMER_RATE_MILLIS = 750L
    }

    private val executorService: ScheduledExecutorService = Executors.newScheduledThreadPool(2)
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var periodicTaskHandle: ScheduledFuture<*>? = null
    private var usageStatsManager: UsageStatsManager? = null

    private var lastUsageQueryTimestamp = System.currentTimeMillis()
    private var lastLaunchedApp = ""
    private val activeApps = mutableListOf<String>()

    private val lockReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> pause()
                Intent.ACTION_USER_PRESENT -> resume()
            }
        }
    }

    fun start() {
        resume()
        try {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_USER_PRESENT)
            }
            context.registerReceiver(lockReceiver, filter)
        } catch (_: Exception) {
            // Registration can be flaky on some OEMs; the poll itself is
            // the safety net, so a missing receiver is not fatal.
        }
    }

    fun dispose() {
        pause()
        try {
            context.unregisterReceiver(lockReceiver)
        } catch (_: Exception) {
        }
        periodicTaskHandle?.cancel(true)
        executorService.shutdownNow()
    }

    private fun pause() {
        periodicTaskHandle?.cancel(true)
        periodicTaskHandle = null
    }

    private fun resume() {
        if (periodicTaskHandle != null) return
        periodicTaskHandle = executorService.scheduleWithFixedDelay(
            { findLaunchedApp() },
            0L,
            TIMER_RATE_MILLIS,
            TimeUnit.MILLISECONDS,
        )
    }

    /** Best-effort current foreground (the first still-active app, or the
     *  last launch we saw). Mirrors Mindful's activeApps.firstOrNull(). */
    val currentForeground: String?
        get() = synchronized(activeApps) {
            activeApps.firstOrNull() ?: lastLaunchedApp.takeIf { it.isNotEmpty() }
        }

    /** Fast path from accessibility events: whatever real app surfaced. */
    fun handleAccessibilityLaunch(packageName: String) {
        if (packageName == lastLaunchedApp || packageName.isEmpty()) return
        invokeNewAppLaunched(packageName)
    }

    /** Fast path from the OS usage events (also used by the poll). */
    fun invokeNewAppLaunched(packageName: String) {
        lastLaunchedApp = packageName
        if (packageName.isEmpty()) return
        // The overlay + performGlobalAction must run on the main thread;
        // the poll fires from the executor, so always hop (posting from
        // the main thread just defers one frame, which is harmless).
        mainHandler.post { onNewAppLaunched.invoke(packageName) }
    }

    private fun findLaunchedApp() {
        try {
            if (usageStatsManager == null) {
                usageStatsManager =
                    context.getSystemService(USAGE_STATS_SERVICE) as? UsageStatsManager
            }
            val usm = usageStatsManager ?: return

            val timeNow = System.currentTimeMillis()
            val start = lastUsageQueryTimestamp
            lastUsageQueryTimestamp = timeNow

            val events = usm.queryEvents(start, timeNow)
            val event = UsageEvents.Event()
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                val pkg = event.packageName?.toString() ?: continue
                when (event.eventType) {
                    UsageEvents.Event.ACTIVITY_RESUMED ->
                        synchronized(activeApps) { if (pkg !in activeApps) activeApps.add(pkg) }

                    UsageEvents.Event.ACTIVITY_PAUSED,
                    UsageEvents.Event.ACTIVITY_STOPPED ->
                        synchronized(activeApps) { activeApps.remove(pkg) }
                }
            }

            val front = synchronized(activeApps) { activeApps.firstOrNull() }
            front?.let {
                if (lastLaunchedApp != it) invokeNewAppLaunched(it)
            }
        } catch (_: Exception) {
            // (SecurityException without usage access, transient errors) —
            // the accessibility fast path keeps detection alive regardless.
        }
    }
}
