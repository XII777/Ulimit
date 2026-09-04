package com.ulimit.app

import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Platform-channel handlers that do NOT require an Activity. Registered
 * on the app's main engine (from MainActivity) AND on the headless
 * background engine the Focus-indicator service spawns, so system-UI
 * actions work with the app swiped away.
 */
object UlimitChannels {

    fun registerCommon(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "com.ulimit.app/enforcement")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pushSnapshot" -> {
                        val obj = org.json.JSONObject()
                        @Suppress("UNCHECKED_CAST")
                        (call.arguments as? Map<String, Any?>)?.forEach { (k, v) ->
                            // CRITICAL: wrap nested Dart structures. The
                            // StandardMessageCodec decodes Dart List/Map as
                            // raw java.util.ArrayList/HashMap, and
                            // JSONObject.toString() STRINGIFIES raw
                            // collections instead of emitting JSON — the
                            // persisted snapshot then parses back with
                            // EMPTY blockedNow/manual while top-level
                            // scalars (pushedAtMillis) survive. Blocking
                            // looked wired but never had a policy. wrap()
                            // converts them to real JSONArray/JSONObject.
                            obj.put(k, org.json.JSONObject.wrap(v))
                        }
                        PolicySnapshot.write(context, obj.toString())
                        // Keep the standalone enforcement service in step
                        // with policy: start it as soon as any restriction
                        // exists, stop it when the user removed them all.
                        if (PolicySnapshot.hasActivePolicy(context)) {
                            BlockGuardService.ensureStarted(context)
                        } else {
                            BlockGuardService.requestStop(context)
                        }
                        if (PolicySnapshot.isDebugBuild(context)) {
                            android.util.Log.d("UlimitBlock", "snapshot pushed (${obj} chars)")
                        }
                        result.success(null)
                    }
                    "getFilterFilePath" -> result.success(
                        java.io.File(context.filesDir, "blocked_domains.txt").absolutePath
                    )
                    "getEnforcementStatus" -> result.success(BlockEngine.diagnostics(context))
                    "reevaluateForeground" -> {
                        BlockEngine.reevaluateForeground()
                        result.success(null)
                    }
                    "reloadDomainFilter" -> {
                        if (UlimitVpnService.isRunning) {
                            val intent = Intent(context, UlimitVpnService::class.java)
                            intent.action = UlimitVpnService.ACTION_RELOAD
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                context.startForegroundService(intent)
                            } else {
                                context.startService(intent)
                            }
                        }
                        result.success(null)
                    }
                    "startVpn" -> {
                        val prepare = android.net.VpnService.prepare(context)
                        if (prepare != null) {
                            result.success(false)
                        } else {
                            PolicySnapshot.prefs(context)
                                .edit().putBoolean(PolicySnapshot.KEY_VPN_ENABLED, true).apply()
                            val intent = Intent(context, UlimitVpnService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                context.startForegroundService(intent)
                            } else {
                                context.startService(intent)
                            }
                            result.success(true)
                        }
                    }
                    "stopVpn" -> {
                        PolicySnapshot.prefs(context)
                            .edit().putBoolean(PolicySnapshot.KEY_VPN_ENABLED, false).apply()
                        val intent = Intent(context, UlimitVpnService::class.java)
                        intent.action = UlimitVpnService.ACTION_STOP
                        context.startService(intent)
                        result.success(true)
                    }
                    "isVpnRunning" -> result.success(UlimitVpnService.isRunning)
                    "setDnd" -> {
                        val enabled = call.arguments as? Boolean ?: false
                        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        if (nm.isNotificationPolicyAccessGranted) {
                            nm.setInterruptionFilter(
                                if (enabled) NotificationManager.INTERRUPTION_FILTER_PRIORITY
                                else NotificationManager.INTERRUPTION_FILTER_ALL
                            )
                            PolicySnapshot.prefs(context).edit()
                                .putBoolean(PolicySnapshot.KEY_BEDTIME_ACTIVE, enabled).apply()
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "setBedtimeGrayscale" -> {
                        val enabled = call.arguments as? Boolean ?: false
                        BedtimeEffects.setGrayscale(context, enabled)
                        result.success(true)
                    }
                    "isDndAccessGranted" -> {
                        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        result.success(nm.isNotificationPolicyAccessGranted)
                    }
                    "openDndAccessSettings" -> {
                        context.startActivity(
                            Intent(android.provider.Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(null)
                    }
                    "setBedtimeAlarms" -> {
                        val args = call.arguments as? Map<*, *>
                        BedtimeScheduler.set(
                            context,
                            enabled = args?.get("enabled") as? Boolean ?: false,
                            startTime = args?.get("startTime") as? String ?: "22:30",
                            endTime = args?.get("endTime") as? String ?: "06:30"
                        )
                        result.success(null)
                    }
                    "getInstalledApps" -> result.success(installedApps(context))
                    // Dart→Kotlin never calls these; they exist so the
                    // Kotlin→Dart focusAction invocations on the same
                    // channel don't collide with the handler map.
                    "focusAction" -> result.success(null)
                    "startFocusIndicator", "stopFocusIndicator", "updateFocusNotification" -> {
                        FocusIndicatorCommands.handle(context, call.method, call.arguments)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun installedApps(context: Context): List<Map<String, Any?>> {
        val pm = context.packageManager
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val activities = pm.queryIntentActivities(launcherIntent, 0)

        val out = mutableListOf<Map<String, Any?>>()
        for (info in activities) {
            val pkg = info.activityInfo.packageName
            if (pkg == context.packageName) continue
            val label = try {
                info.loadLabel(pm)?.toString() ?: pkg
            } catch (_: Exception) {
                pkg
            }
            val icon = try {
                info.loadIcon(pm)
            } catch (_: Exception) {
                null
            }
            out.add(
                mapOf(
                    "package" to pkg,
                    "name" to label,
                    "icon" to icon?.let { drawableToPng(it) }
                )
            )
        }
        out.sortBy { (it["name"] as String).lowercase() }
        return out
    }

    private fun drawableToPng(drawable: android.graphics.drawable.Drawable): ByteArray {
        val size = 96
        val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        val bytes = java.io.ByteArrayOutputStream()
        bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 90, bytes)
        bitmap.recycle()
        return bytes.toByteArray()
    }
}

/** Focus-indicator service commands, callable from any engine. */
object FocusIndicatorCommands {
    fun handle(context: Context, method: String, arguments: Any?) {
        val args = arguments as? Map<*, *>
        // All paths are best-effort presentation: background-start
        // restrictions (ForegroundServiceStartNotAllowedException) and
        // rare OEM failures must never crash the host process.
        try {
            when (method) {
                "startFocusIndicator" -> {
                    val intent = Intent(context, FocusIndicatorService::class.java).apply {
                        action = FocusIndicatorService.ACTION_START
                        putExtra(FocusIndicatorService.EXTRA_LABEL, args?.get("label") as? String ?: "Focus")
                        putExtra(
                            FocusIndicatorService.EXTRA_STARTED_AT,
                            (args?.get("startedAtMillis") as? Number)?.toLong() ?: 0L
                        )
                        putExtra(
                            FocusIndicatorService.EXTRA_END,
                            (args?.get("endMillis") as? Number)?.toLong() ?: 0L
                        )
                        putExtra(FocusIndicatorService.EXTRA_PAUSED, args?.get("paused") as? Boolean ?: false)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                }
                "updateFocusNotification" -> {
                    val intent = Intent(context, FocusIndicatorService::class.java).apply {
                        action = FocusIndicatorService.ACTION_UPDATE
                        putExtra(FocusIndicatorService.EXTRA_LABEL, args?.get("label") as? String ?: "Focus")
                        putExtra(
                            FocusIndicatorService.EXTRA_END,
                            (args?.get("endMillis") as? Number)?.toLong() ?: 0L
                        )
                        putExtra(FocusIndicatorService.EXTRA_PAUSED, args?.get("paused") as? Boolean ?: false)
                        // Live doomscroll counting (optional fields).
                        val doomPkg = args?.get("doomPackage") as? String
                        if (doomPkg != null) {
                            putExtra(FocusIndicatorService.EXTRA_DOOM_PACKAGE, doomPkg)
                            putExtra(
                                FocusIndicatorService.EXTRA_DOOM_COUNT,
                                (args["doomCount"] as? Number)?.toInt() ?: 0
                            )
                        }
                    }
                    // The service is already a FGS when updates arrive;
                    // startForegroundService is safe from background.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                }
                "stopFocusIndicator" -> {
                    val intent = Intent(context, FocusIndicatorService::class.java).apply {
                        action = FocusIndicatorService.ACTION_STOP
                    }
                    context.startService(intent)
                }
            }
        } catch (_: Exception) {
        }
    }
}

/** Bedtime alarm scheduling shared by the Activity and background engines. */
object BedtimeScheduler {
    fun set(context: Context, enabled: Boolean, startTime: String, endTime: String) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val startPending = bedtimePending(context, BedtimeAlarmReceiver.ACTION_BEDTIME_START, 6001)
        val endPending = bedtimePending(context, BedtimeAlarmReceiver.ACTION_BEDTIME_END, 6002)
        am.cancel(startPending)
        am.cancel(endPending)
        if (!enabled) return

        fun minutesOf(hhmm: String): Int {
            val parts = hhmm.split(":")
            return (parts.getOrNull(0)?.toIntOrNull() ?: 0) * 60 + (parts.getOrNull(1)?.toIntOrNull() ?: 0)
        }

        fun nextOccurrence(minutes: Int): Long {
            val cal = java.util.Calendar.getInstance().apply {
                set(java.util.Calendar.HOUR_OF_DAY, minutes / 60)
                set(java.util.Calendar.MINUTE, minutes % 60)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }
            if (cal.timeInMillis <= System.currentTimeMillis()) {
                cal.add(java.util.Calendar.DAY_OF_YEAR, 1)
            }
            return cal.timeInMillis
        }

        val startAt = nextOccurrence(minutesOf(startTime))
        val endAt = nextOccurrence(minutesOf(endTime))

        fun schedule(triggerAt: Long, pending: android.app.PendingIntent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !am.canScheduleExactAlarms()) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            } else {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            }
        }

        schedule(startAt, startPending)
        schedule(endAt, endPending)
    }

    private fun bedtimePending(context: Context, action: String, requestCode: Int): android.app.PendingIntent {
        val intent = Intent(context, BedtimeAlarmReceiver::class.java).apply { this.action = action }
        var flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or android.app.PendingIntent.FLAG_IMMUTABLE
        }
        return android.app.PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }
}
