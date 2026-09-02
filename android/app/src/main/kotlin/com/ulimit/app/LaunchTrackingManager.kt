package com.ulimit.app

import android.app.Service.USAGE_STATS_SERVICE
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Detects which app is in the foreground and fires [onNewAppLaunched]
 * for every foreground change — the OS UsageEvents stream (ACTIVITY_
 * RESUMED / PAUSED / STOPPED) polled every [TIMER_RATE_MILLIS] on a
 * dedicated executor, hosted by [BlockGuardService].
 *
 * This is the detector that keeps blocking alive WITHOUT the
 * accessibility service: the accessibility fast path is instant but
 * can be disabled/reset by the user or an OEM; this poll only needs
 * Usage Access and the guard service being alive.
 *
 * Foreground model: `activeApps` holds every package that resumed and
 * hasn't paused/stopped. On RESUMED the package moves to the END of
 * the list, so the LAST element is the most recently resumed (i.e.
 * the focused) app — the old implementation took `firstOrNull()`,
 * which returned the OLDEST resumed app and mis-attributed the
 * foreground while PAUSED events were still in flight.
 *
 * Dedupe policy: consecutive identical foregrounds are collapsed here,
 * but a RE-entry (resume → pause → resume of the same app) always
 * re-fires. The old `handleAccessibilityLaunch` dedupe that silently
 * swallowed a re-launched blocked app is gone — accessibility events
 * bypass this class entirely and go straight to [BlockEngine], which
 * owns enforcement-side dedupe.
 */
class LaunchTrackingManager(
    private val context: Context,
    private val onNewAppLaunched: (String) -> Unit,
    private val onScreenStateChanged: (screenOn: Boolean) -> Unit = {},
) {
    companion object {
        private const val TIMER_RATE_MILLIS = 750L
    }

    private val executorService: ScheduledExecutorService = Executors.newScheduledThreadPool(2)
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var periodicTaskHandle: ScheduledFuture<*>? = null
    private var usageStatsManager: UsageStatsManager? = null

    private var lastUsageQueryTimestamp = System.currentTimeMillis()
    private var lastLaunchedApp = ""

    /** Most-recently-resumed first... no: last element = foreground. */
    private val activeApps = mutableListOf<String>()

    private val lockReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    onScreenStateChanged(false)
                    pause()
                }
                Intent.ACTION_SCREEN_ON, Intent.ACTION_USER_PRESENT -> {
                    onScreenStateChanged(true)
                    resume()
                    // Re-sync immediately instead of waiting a tick: the
                    // foreground at unlock may already be a blocked app.
                    executorService.submit { findLaunchedApp() }
                }
            }
        }
    }

    fun start() {
        resume()
        try {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
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

    /** Best-effort current foreground: the most recently resumed app
     *  that hasn't paused, or the last launch we saw. */
    val currentForeground: String?
        get() = synchronized(activeApps) {
            activeApps.lastOrNull() ?: lastLaunchedApp.takeIf { it.isNotEmpty() }
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
            synchronized(activeApps) {
                while (events.hasNextEvent()) {
                    events.getNextEvent(event)
                    val pkg = event.packageName?.toString() ?: continue
                    when (event.eventType) {
                        UsageEvents.Event.ACTIVITY_RESUMED -> {
                            // Move to the END: most recently resumed = focused.
                            activeApps.remove(pkg)
                            activeApps.add(pkg)
                        }

                        UsageEvents.Event.ACTIVITY_PAUSED,
                        UsageEvents.Event.ACTIVITY_STOPPED,
                        -> activeApps.remove(pkg)
                    }
                }
            }

            val front = synchronized(activeApps) { activeApps.lastOrNull() }
            front?.let {
                if (lastLaunchedApp != it) invokeNewAppLaunched(it)
            }
        } catch (_: Exception) {
            // (SecurityException without usage access, transient errors) —
            // nothing to do; the accessibility fast path is independent.
        }
    }

    private fun invokeNewAppLaunched(packageName: String) {
        lastLaunchedApp = packageName
        if (packageName.isEmpty()) return
        // The engine hops to the main thread itself; post from the
        // executor to keep ordering predictable.
        mainHandler.post { onNewAppLaunched.invoke(packageName) }
    }
}
