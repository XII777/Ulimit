package com.ulimit.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * The Android system-level Focus Session indicator: a foreground service
 * whose notification is posted as a CALL-STYLE ongoing notification on
 * API 31+ — the same "status bar chip with a live duration" treatment
 * WhatsApp/phone apps get for ongoing calls:
 *
 *  - The status bar shows a chip/timer with the session elapsed time
 *    (chronometer on the notification, like a call-in-progress pill).
 *  - Tapping the chip opens [FocusSessionPopupActivity] — a small
 *    spring-bouncy panel with Pause/Resume/End, so the chip UX is a
 *    popup, not the full app.
 *  - Pause/Resume/End actions (notification buttons + popup) route back
 *    into the Dart FocusController through the platform channel — ONE
 *    source of truth for session state.
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
        // Doomscroll live counting: package the user is currently in
        // (when it's a doomscroll platform) + today's opens for it. The
        // notification text becomes "12 opens today · Reels" while the
        // user scrolls — per-second-ish updates from Dart's own tick.
        const val EXTRA_DOOM_PACKAGE = "doomPackage"
        const val EXTRA_DOOM_COUNT = "doomCount"

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
                DartExecutor.DartEntrypoint(bundlePath, "backgroundMain")
            )
            // Kotlin-side handlers for the headless engine (the Dart side
            // registers its focusAction handler in backgroundMain itself).
            UlimitChannels.registerCommon(context, engine.dartExecutor.binaryMessenger)
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
    private var doomPackage: String? = null
    private var doomCount: Int = 0

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
                doomPackage = intent.getStringExtra(EXTRA_DOOM_PACKAGE)
                doomCount = intent.getIntExtra(EXTRA_DOOM_COUNT, doomCount)
                pushNotification()
            }
        }
        return START_STICKY
    }

    private fun startAsForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // phoneCall type (manifest): REQUIRED for CallStyle — an
            // SPECIAL_USE-typed service's CallStyle notification is
            // rejected/demoted on Android 14+.
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
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
            .setContentIntent(chipClickIntent())
            .addAction(buildAction("End", FocusSessionActionReceiver.ACTION_END, 11))

        // The LIVE DURATION CHIP: an ongoing call-style notification
        // makes the system show the elapsed-time chip/pill in the status
        // bar (exactly like a phone call in progress). The chronometer
        // keeps the chip ticking without per-second app updates; while
        // paused we freeze it at the current remaining text.
        if (paused) {
            val remaining = ((endMillis - System.currentTimeMillis()) / 1000).coerceAtLeast(0)
            val mm = remaining / 60
            val ss = remaining % 60
            builder
                .setContentText("Paused · %02d:%02d remaining".format(mm, ss))
                .addAction(buildAction("Resume", FocusSessionActionReceiver.ACTION_RESUME, 10))
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                builder
                    .setUsesChronometer(true)
                    .setChronometerCountDown(true)
                    .setWhen(endMillis)
            } else {
                val remaining = ((endMillis - System.currentTimeMillis()) / 1000).coerceAtLeast(0)
                val mm = remaining / 60
                val ss = remaining % 60
                builder.setContentText("%02d:%02d remaining".format(mm, ss))
            }
            builder.addAction(buildAction("Pause", FocusSessionActionReceiver.ACTION_PAUSE, 10))
        }

        // Live doomscroll counting: while the user is scrolling one of
        // the infinite-feed apps, the notification shows today's open
        // count right in the chip ("12 opens today · TikTok"). Pushed on
        // every foreground transition, not per second.
        val doomPkg = doomPackage
        if (doomPkg != null && doomCount > 0) {
            val appName = try {
                packageManager.getApplicationLabel(
                    packageManager.getApplicationInfo(doomPkg, 0)
                ).toString()
            } catch (_: Exception) {
                doomPkg
            }
            builder.setSubText("$doomCount opens today · $appName")
        }

        // API 31+: promote to the call-style surface. A normal ongoing
        // notification never paints the status-bar duration chip; the
        // call style is what gives us the WhatsApp-call treatment.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder()
                .setName("Focus · $label")
                .setImportant(true)
                .build()
            val callStyle = Notification.CallStyle
                .forOngoingCall(person, chipClickIntent())
            builder.setStyle(callStyle)
            builder.setCategory(Notification.CATEGORY_CALL)
        }

        return builder.build()
    }

    /** Chip tap target. On API 31+ the call-style chip's tap PendingIntent
     *  opens the spring-bouncy popup panel; otherwise it opens the app. */
    private fun chipClickIntent(): PendingIntent {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Intent(this, FocusSessionPopupActivity::class.java).apply {
                putExtra(FocusSessionPopupActivity.EXTRA_LABEL, label)
                putExtra(FocusSessionPopupActivity.EXTRA_PAUSED, paused)
            }
        } else {
            packageManager.getLaunchIntentForPackage(packageName) ?: Intent()
        }
        return PendingIntent.getActivity(
            this, 7, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun buildAction(title: String, action: String, requestCode: Int): Notification.Action {
        val intent = Intent(this, FocusSessionActionReceiver::class.java).apply {
            this.action = action
        }
        val pending = PendingIntent.getBroadcast(
            this, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val icon = Icon.createWithResource(
            this, android.R.drawable.ic_media_play
        )
        return Notification.Action.Builder(icon, title, pending).build()
    }

    private fun pushNotification() {
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
