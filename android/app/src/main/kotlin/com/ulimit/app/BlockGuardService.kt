package com.ulimit.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * The standalone enforcement core — a persistent foreground service
 * that keeps app blocking alive on its own:
 *
 *  - hosts the [LaunchTrackingManager] UsageEvents poll (the detector
 *    that works with zero accessibility),
 *  - keeps the process alive so the accessibility service can't be
 *    quietly reaped and the poll never sleeps,
 *  - draws the block pop-layer itself (TYPE_APPLICATION_OVERLAY) when
 *    accessibility is unavailable but "Display over other apps" is
 *    granted — Mindful's exact fallback stack —
 *  - posts a heads-up "app blocked" notification when NO overlay host
 *    can draw, so a block never degrades to total silence,
 *  - restarts itself after process death (START_STICKY) and reboots
 *    ([BootReceiver]).
 *
 * Independence rules (the reason this service exists): it reads ONLY
 * the persisted [PolicySnapshot] — never the VPN, never Dart, never
 * the UI. If the user set an app to be blocked, this service blocks
 * it regardless of every other feature's state.
 */
class BlockGuardService : Service() {

    companion object {
        private const val TAG = "UlimitBlock"
        const val CHANNEL_ID = "enforcement_guard"
        const val ALERT_CHANNEL_ID = "block_alerts"
        const val NOTIFICATION_ID = 3002
        const val ALERT_NOTIFICATION_ID = 3003
        const val ACTION_STOP = "com.ulimit.app.blockguard.STOP"

        var isRunning: Boolean = false
            private set

        /** Last heads-up "blocked" notify per package (throttle). */
        private val lastAlertAt = HashMap<String, Long>()
        private const val ALERT_THROTTLE_MS = 10_000L

        /** Starts the guard if any policy is configured. Safe to call
         *  from anywhere (boot receiver, channel handler, activity,
         *  accessibility service); FGS-from-background restrictions are
         *  swallowed — the other start paths cover the gap. */
        fun ensureStarted(context: Context) {
            if (isRunning) return
            if (!PolicySnapshot.hasActivePolicy(context)) return
            try {
                val intent = Intent(context, BlockGuardService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                if (PolicySnapshot.isDebugBuild(context)) {
                    Log.d(TAG, "guard start skipped: ${e.message}")
                }
            }
        }

        /** Stops the guard when the user removed every restriction. */
        fun requestStop(context: Context) {
            if (!isRunning) return
            try {
                context.startService(
                    Intent(context, BlockGuardService::class.java).apply {
                        action = ACTION_STOP
                    }
                )
            } catch (_: Exception) {
            }
        }

        /** Ejects to the home screen without accessibility. Starting an
         *  activity from the background is one of Android's documented
         *  exemptions for apps holding SYSTEM_ALERT_WINDOW — the exact
         *  permission the guard overlay path requires. */
        fun goHome(context: Context?) {
            if (context == null) return
            try {
                context.startActivity(
                    Intent(Intent.ACTION_MAIN)
                        .addCategory(Intent.CATEGORY_HOME)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Exception) {
            }
        }

        /** Heads-up fallback when no overlay host can draw. Throttled
         *  per package so a mashing user can't spam the shade. */
        fun notifyBlocked(context: Context, pkg: String) {
            try {
                val now = System.currentTimeMillis()
                synchronized(lastAlertAt) {
                    val last = lastAlertAt[pkg] ?: 0L
                    if (now - last < ALERT_THROTTLE_MS) return
                    lastAlertAt[pkg] = now
                }
                val appName = try {
                    val pm = context.packageManager
                    pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0))?.toString() ?: pkg
                } catch (_: Exception) {
                    pkg
                }
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    nm.createNotificationChannel(
                        NotificationChannel(
                            ALERT_CHANNEL_ID, "Blocked app alerts",
                            NotificationManager.IMPORTANCE_HIGH
                        ).apply { setShowBadge(false) }
                    )
                }
                val openApp = PendingIntent.getActivity(
                    context, 12,
                    context.packageManager.getLaunchIntentForPackage(context.packageName),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Notification.Builder(context, ALERT_CHANNEL_ID)
                } else {
                    @Suppress("DEPRECATION")
                    Notification.Builder(context)
                }
                    .setContentTitle("$appName is blocked")
                    .setContentText("Blocked by Ulimit — leave the app to continue.")
                    .setSmallIcon(android.R.drawable.ic_lock_lock)
                    .setAutoCancel(true)
                    .setContentIntent(openApp)
                nm.notify(ALERT_NOTIFICATION_ID, builder.build())
            } catch (_: Exception) {
            }
        }
    }

    private lateinit var tracking: LaunchTrackingManager
    private lateinit var overlay: BlockOverlayManager

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        overlay = BlockOverlayManager(this, android.view.WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY)
        tracking = LaunchTrackingManager(
            context = this,
            onNewAppLaunched = { pkg -> BlockEngine.onAppLaunch(pkg) },
            onScreenStateChanged = { screenOn ->
                if (screenOn) BlockEngine.onUnlocked() else BlockEngine.onScreenOff()
            },
        )
        BlockEngine.attachGuard(overlay) { tracking.currentForeground }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Any start path must promote to foreground immediately.
        startAsForeground()

        if (intent?.action == ACTION_STOP) {
            stopEverything()
            return START_NOT_STICKY
        }

        if (!tracking.currentForeground.isNullOrEmpty()) {
            // Fresh start (boot/service restart): check whatever is
            // already foreground instead of waiting for a transition.
            BlockEngine.reevaluateForeground()
        }
        return START_STICKY
    }

    private fun startAsForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        isRunning = true
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Blocking service", NotificationManager.IMPORTANCE_MIN
            )
            channel.description = "Keeps app blocking active in the background"
            channel.setShowBadge(false)
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
            .setContentTitle("Blocking is active")
            .setContentText("Ulimit is enforcing your restrictions.")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setContentIntent(
                PendingIntent.getActivity(
                    this, 13,
                    packageManager.getLaunchIntentForPackage(packageName),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
        return builder.build()
    }

    private fun stopEverything() {
        isRunning = false
        BlockEngine.detachGuard(overlay)
        tracking.dispose()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away from recents — keep the guard running; it IS the
        // point of the service. Nothing to do (START_STICKY also covers
        // process death), but re-assert foreground state cheaply.
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }
}
