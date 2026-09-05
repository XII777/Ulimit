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

        /// Why the pill may be missing: the reason the LAST attempted
        /// foreground promotion degraded or failed — null when
        /// everything went cleanly. Read by the copyable report.
        @Volatile var lastStartError: String? = null
            private set

        fun areNotificationsEnabled(context: Context): Boolean =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                (context.getSystemService(android.content.Context.NOTIFICATION_SERVICE)
                    as android.app.NotificationManager).areNotificationsEnabled()
            } else {
                true
            }

        fun channelImportance(context: Context): Int =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                (context.getSystemService(android.content.Context.NOTIFICATION_SERVICE)
                    as android.app.NotificationManager)
                    .getNotificationChannel(CHANNEL_ID)?.importance ?: -1
            } else {
                -1
            }

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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Runtime-notification denial kills the pill silently on
            // stock AND ColorOS — surface it for diagnostics.
            lastStartError = if (!areNotificationsEnabled(this)) {
                "notifications disabled for the app"
            } else null
        }
        // Escalating attempt ladder: OEM stacks (ColorOS here) reject
        // individual FGS types inconsistently; whichever start succeeds
        // wins, and the FIRST REASON is recorded for the report instead
        // of a silent dead pill.
        val notification = buildNotification()
        val errors = StringBuilder()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // phoneCall type: REQUIRED for CallStyle — a
            // specialUse-typed service's CallStyle notification is
            // rejected/demoted on Android 14+.
            try {
                startForeground(
                    NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                )
                isRunning = true
                return
            } catch (t: Throwable) {
                errors.append("phoneCall: ${t.message}; ")
            }
            try {
                startForeground(
                    NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
                isRunning = true
                lastStartError = "phoneCall rejected ($errors)→specialUse"
                return
            } catch (t: Throwable) {
                errors.append("specialUse: ${t.message}; ")
            }
        }
        try {
            startForeground(NOTIFICATION_ID, notification)
            isRunning = true
            lastStartError = if (errors.isEmpty()) null else "typed starts rejected ($errors)→untyped"
        } catch (t: Throwable) {
            isRunning = false
            lastStartError = "$errors untyped: ${t.message}"
            stopSelf()
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Focus Session", NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Active Focus Session timer"
            channel.setShowBadge(false)
            // Theme accent: pure white — the app is monochrome, and the
            // system tints the small icon + buttons with this.
            channel.enableLights(false)
            channel.enableVibration(false)
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
            // The focus-ring glyph (broken circle + centre dot) — the
            // app's meditation/focus icon replacing the old media-play
            // stand-in, theme white.
            .setSmallIcon(R.drawable.ic_stat_focus)
            .setColor(0xFFFFFFFF.toInt())
            .setColorized(false)
            .setContentTitle(label)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openPopupIntent())

        // The LIVE timer (WhatsApp-call-style pill, no negative sign):
        // a count-UP chronometer from the session's start — elapsed can
        // only grow, so "-MM:SS" is structurally impossible even if the
        // session overruns its end by seconds before Dart settles it.
        // Paused sessions freeze the chronometer and say so.
        //
        // Session progress as the thin determinate bar the system
        // paints under the text — mirrors the ring the in-app running
        // view shows.
        if (startedAtMillis > 0L && endMillis > startedAtMillis) {
            val total = endMillis - startedAtMillis
            val elapsed = (System.currentTimeMillis() - startedAtMillis).coerceIn(0L, total)
            builder.setProgress(100, ((elapsed * 100) / total).toInt(), false)
        }

        // Primary action first (pause/resume), End second — the order
        // OEMs expand consistently.
        if (paused) {
            builder.setContentText("Paused")
            builder.addAction(
                buildAction("Resume", FocusSessionActionReceiver.ACTION_RESUME, 10,
                    R.drawable.ic_focus_play)
            )
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                builder
                    .setUsesChronometer(true)
                    .setWhen(startedAtMillis)
            }
            builder.setContentText("Running")
            builder.addAction(
                buildAction("Pause", FocusSessionActionReceiver.ACTION_PAUSE, 10,
                    R.drawable.ic_focus_pause)
            )
        }
        builder.addAction(
            buildAction("End", FocusSessionActionReceiver.ACTION_END, 11,
                R.drawable.ic_focus_end)
        )

        // Live doomscroll counting: while the user is scrolling one of
        // the infinite-feed apps, the notification shows today's live
        // scroll count right in the chip ("12 scrolls · TikTok"). Pushed
        // on every foreground transition, not per second.
        val doomPkg = doomPackage
        if (doomPkg != null && doomCount > 0) {
            val appName = try {
                packageManager.getApplicationLabel(
                    packageManager.getApplicationInfo(doomPkg, 0)
                ).toString()
            } catch (_: Exception) {
                doomPkg
            }
            builder.setSubText("$doomCount scrolls today · $appName")
        }

        // API 31+: promote to the call-style surface — it is the only
        // channel to the status-bar DURATION PILL. The old generic
        // Person avatar rendered as the system "call person" glyph —
        // the call icon; the avatar now carries the app's focus-ring
        // icon instead, so the pill reads meditation/focus, not phone.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder()
                .setName(label)
                .setIcon(Icon.createWithResource(this, R.drawable.ic_stat_focus))
                .setImportant(true)
                .build()
            val callStyle = Notification.CallStyle
                .forOngoingCall(person, openPopupIntent())
            builder.setStyle(callStyle)
            builder.setCategory(Notification.CATEGORY_CALL)
        }

        return builder.build()
    }

    /** Chip tap target. On API 31+ the call-style chip's tap PendingIntent
     *  opens the spring-bouncy popup panel; otherwise it opens the app. */
    private fun openPopupIntent(): PendingIntent {
        val intent = Intent(this, FocusSessionPopupActivity::class.java).apply {
            putExtra(FocusSessionPopupActivity.EXTRA_LABEL, label)
            putExtra(FocusSessionPopupActivity.EXTRA_PAUSED, paused)
            putExtra(FocusSessionPopupActivity.EXTRA_END, endMillis)
            putExtra(FocusSessionPopupActivity.EXTRA_STARTED_AT, startedAtMillis)
            // The popup needs the live counter state too — same fields
            // as the notification.
            doomPackage?.let {
                putExtra(FocusSessionPopupActivity.EXTRA_DOOM_PACKAGE, it)
                putExtra(FocusSessionPopupActivity.EXTRA_DOOM_COUNT, doomCount)
            }
        }
        return PendingIntent.getActivity(
            this, 7, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun buildAction(
        title: String,
        action: String,
        requestCode: Int,
        iconRes: Int = R.drawable.ic_focus_end,
    ): Notification.Action {
        val intent = Intent(this, FocusSessionActionReceiver::class.java).apply {
            this.action = action
        }
        val pending = PendingIntent.getBroadcast(
            this, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val icon = Icon.createWithResource(this, iconRes)
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
