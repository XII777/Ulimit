package com.ulimit.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartEntrypoint

/**
 * The Android system-level Focus Session indicator: a foreground service
 * whose ongoing notification carries a live countdown chronometer plus
 * Pause/Resume/End actions. It is a PRESENTATION surface only — every
 * action routes back into the Dart FocusController through the platform
 * channel, so there is exactly one source of truth for the session.
 *
 * Engine strategy: when the app's Activity engine is alive it is reused
 * (cached under [ENGINE_ID]); otherwise a headless background engine is
 * created on the "backgroundMain" entrypoint so the actions work even
 * with the app swiped away. The engine is kept for the service lifetime
 * and destroyed on stop.
 */
class FocusIndicatorService : Service() {

    companion object {
        const val CHANNEL_ID = "focus_session"
        const val NOTIFICATION_ID = 3001

        const val ACTION_START = "com.ulimit.app.focus.START"
        const val ACTION_UPDATE = "com.ulimit.app.focus.UPDATE"
        const val ACTION_STOP = "com.ulimit.app.focus.STOP"

        const val EXTRA_LABEL = "label"
        const val EXTRA_STARTED_AT = "startedAtMillis"
        const val EXTRA_END = "endMillis"
        const val EXTRA_PAUSED = "paused"

        const val ENGINE_ID = "ulimit_main_engine"
        const val BG_ENGINE_ID = "ulimit_bg_engine"

        var isRunning: Boolean = false
            private set

        private var backgroundEngine: FlutterEngine? = null

        /**
         * Returns the engine the focusAction call should target: the
         * app's engine when alive, a headless engine otherwise. The
         * headless engine runs "backgroundMain", which registers the
         * same platform-channel handlers against a private container.
         */
        @Synchronized
        fun ensureEngine(context: Context): FlutterEngine {
            FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }

            backgroundEngine?.let { return it }

            // Headless engine on the "backgroundMain" entrypoint: it
            // registers the same platform-channel handlers against a
            // private ProviderContainer (no UI, no router).
            val engine = FlutterEngine(context)
            val bundlePath = FlutterInjector.instance().flutterLoader().findAppBundlePath()
            engine.dartExecutor.executeDartEntrypoint(
                DartEntrypoint(bundlePath, "backgroundMain")
            )
            FlutterEngineCache.getInstance().put(BG_ENGINE_ID, engine)
            backgroundEngine = engine
            return engine
        }

        fun destroyBackgroundEngine() {
            backgroundEngine?.destroy()
            backgroundEngine = null
            FlutterEngineCache.getInstance().remove(BG_ENGINE_ID)
        }
    }

    private var label: String = "Focus"
    private var startedAtMillis: Long = 0
    private var endMillis: Long = 0
    private var paused: Boolean = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Any start path must promote to foreground immediately.
        startAsForeground()

        when (intent?.action) {
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }
            ACTION_START, ACTION_UPDATE -> {
                label = intent.getStringExtra(EXTRA_LABEL) ?: label
                startedAtMillis = intent.getLongExtra(EXTRA_STARTED_AT, startedAtMillis)
                endMillis = intent.getLongExtra(EXTRA_END, endMillis)
                paused = intent.getBooleanExtra(EXTRA_PAUSED, paused)
                notify()
            }
        }
        return START_NOT_STICKY
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
                CHANNEL_ID, "Focus Session", NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Active Focus Session timer"
            channel.setShowBadge(false)
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val openApp = packageManager.getLaunchIntentForPackage(packageName) ?: Intent()
        val contentIntent = PendingIntent.getActivity(
            this, 0, openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
            .setContentTitle("Focus · $label")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(contentIntent)
            .addAction(buildAction("End session", FocusSessionActionReceiver.ACTION_END, 11))

        if (paused) {
            val remaining = ((endMillis - System.currentTimeMillis()) / 1000).coerceAtLeast(0)
            val mm = remaining / 60
            val ss = remaining % 60
            builder.setContentText("Paused · %02d:%02d remaining".format(mm, ss))
        } else {
            // Chronometer-based countdown: System UI ticks the timer
            // itself — no per-second updates from the app.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                builder.setUsesChronometer(true)
                builder.setChronometerCountDown(true)
                builder.setWhen(endMillis)
            } else {
                val remaining = ((endMillis - System.currentTimeMillis()) / 1000).coerceAtLeast(0)
                val mm = remaining / 60
                val ss = remaining % 60
                builder.setContentText("%02d:%02d remaining".format(mm, ss))
            }
            builder.addAction(buildAction("Pause", FocusSessionActionReceiver.ACTION_PAUSE, 10))
        }

        return builder.build()
    }

    private fun buildAction(title: String, action: String, requestCode: Int): Notification.Action {
        val intent = Intent(this, FocusSessionActionReceiver::class.java).apply {
            this.action = action
        }
        val pending = PendingIntent.getBroadcast(
            this, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val icon = android.graphics.drawable.Icon.createWithResource(
            this, android.R.drawable.ic_media_play
        )
        return Notification.Action.Builder(icon, title, pending).build()
    }

    private fun notify() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun stopEverything() {
        isRunning = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }
}
