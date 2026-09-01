package com.ulimit.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The app's engine. Permissions/UI channels are registered here; the
 * shared, engine-independent handlers live in [UlimitChannels] and are
 * also registered on the headless background engine (see
 * [FocusIndicatorService.ensureEngine]) so system-UI actions work
 * without the Activity.
 *
 * This Activity's engine is cached under [FocusIndicatorService.ENGINE_ID]
 * so the focus indicator reuses it whenever the app is alive.
 */
class MainActivity : FlutterFragmentActivity() {

    private val permissionsChannelName = "com.ulimit.app/permissions"
    private val usageEventsChannelName = "com.ulimit.app/usage_events"

    private val postNotificationsRequestCode = 5002
    private val importRequestCode = 5003

    // Kept alive across the async import flow — the channel result must
    // be completed exactly once, after the document picker returns.
    private var pendingImportResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Cache this engine so the FocusIndicatorService reuses it
        // instead of spawning a headless one while the app is alive.
        FlutterEngineCache.getInstance()
            .put(FocusIndicatorService.ENGINE_ID, flutterEngine)

        // Engine-independent handlers (enforcement, VPN, DND, bedtime,
        // focus indicator, app catalog).
        UlimitChannels.registerCommon(applicationContext, flutterEngine.dartExecutor.binaryMessenger)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, permissionsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAccessibilityEnabled" -> result.success(isAccessibilityServiceEnabled())
                    "openAccessibilitySettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(null)
                    }
                    "isDeviceAdminActive" -> result.success(isDeviceAdminActive())
                    "requestDeviceAdmin" -> {
                        val intent = Intent(android.app.admin.DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
                            putExtra(
                                android.app.admin.DevicePolicyManager.EXTRA_DEVICE_ADMIN,
                                deviceAdminComponent()
                            )
                            putExtra(
                                android.app.admin.DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                                "Protects Ulimit's limits from being bypassed by uninstalling or force-stopping the app."
                            )
                        }
                        startActivity(intent)
                        result.success(null)
                    }
                    "isNotificationListenerEnabled" -> result.success(isNotificationListenerEnabled())
                    "openNotificationListenerSettings" -> {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(null)
                    }
                    "hasVpnPermission" -> result.success(android.net.VpnService.prepare(this) == null)
                    "requestVpnPermission" -> {
                        val intent = android.net.VpnService.prepare(this)
                        if (intent != null) {
                            startActivityForResult(intent, 5001)
                        }
                        result.success(null)
                    }
                    "isPostNotificationsGranted" -> result.success(isPostNotificationsGranted())
                    "requestPostNotifications" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            androidx.core.app.ActivityCompat.requestPermissions(
                                this,
                                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                                postNotificationsRequestCode
                            )
                        }
                        result.success(null)
                    }
                    "isBiometricAvailable" -> result.success(isBiometricAvailable())
                    "authenticate" -> authenticate(call.arguments as? String ?: "Authenticate", result)
                    "isUsageAccessGranted" -> result.success(isUsageAccessGranted())
                    "openUsageAccessSettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                        } catch (_: Exception) {
                            // Some OEMs hide the direct action — Settings hub
                            // still contains it under Personal > Usage access.
                            startActivity(Intent(Settings.ACTION_SETTINGS))
                        }
                        result.success(null)
                    }
                    "fetchDeviceUsageForDays" -> result.success(
                        fetchDeviceUsageForDays(call.arguments as? Int ?: 7)
                    )
                    "fetchAppHourlyUsage" -> result.success(
                        fetchAppHourlyUsage(call.arguments as? String ?: "")
                    )
                    "fetchAppHourlyUsageForDay" -> result.success(
                        fetchAppHourlyUsageForDay(
                            (call.arguments as? Map<*, *>)?.get("packageName") as? String ?: "",
                            (call.arguments as? Map<*, *>)?.get("dayStartMillis")
                                ?.toString()?.toLongOrNull() ?: System.currentTimeMillis()
                        )
                    )
                    "fetchDayHourlyUsage" -> result.success(
                        fetchDayHourlyUsage(call.arguments as? Long ?: System.currentTimeMillis())
                    )
                    "fetchDeviceHourlyUsage" -> result.success(fetchDeviceHourlyUsage())
                    "exportData" -> result.success(exportData(call.arguments as? String ?: "{}"))
                    "importData" -> pendingImportResult = result
                    else -> result.notImplemented()
                }
            }

        // Bridges UlimitAccessibilityService's foreground-app events into
        // Dart. The service and the Flutter engine share this app's
        // process, so a simple static sink (see UsageEventBridge) is
        // enough — no need for a cross-process IPC mechanism.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, usageEventsChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    UsageEventBridge.sink = events
                }

                override fun onCancel(arguments: Any?) {
                    UsageEventBridge.sink = null
                }
            })
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Only drop the cache if it still points at this engine.
        if (FlutterEngineCache.getInstance().get(FocusIndicatorService.ENGINE_ID) === flutterEngine) {
            FlutterEngineCache.getInstance().remove(FocusIndicatorService.ENGINE_ID)
        }
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun putAll(target: org.json.JSONObject, map: Map<String, Any?>?) {
        if (map == null) return
        for ((k, v) in map) target.put(k, v)
    }

    // ------------------------------------------------------------------
    // Biometric authentication (Invincible Mode)
    // ------------------------------------------------------------------

    private fun isBiometricAvailable(): Boolean {
        val biometricManager = BiometricManager.from(this)
        return biometricManager.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL
        ) == BiometricManager.BIOMETRIC_SUCCESS
    }

    private fun authenticate(reason: String, result: MethodChannel.Result) {
        if (!isBiometricAvailable()) {
            result.success(false)
            return
        }
        val executor = ContextCompat.getMainExecutor(this)
        val prompt = BiometricPrompt(
            this,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                    result.success(true)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    result.success(false)
                }
            }
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Authenticate")
            .setSubtitle(reason)
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL
            )
            .build()
        prompt.authenticate(info)
    }

    // ------------------------------------------------------------------
    // Data export / import
    // ------------------------------------------------------------------

    private fun exportData(json: String): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.Downloads.DISPLAY_NAME, "ulimit-export-${System.currentTimeMillis()}.json")
                    put(android.provider.MediaStore.Downloads.MIME_TYPE, "application/json")
                    put(android.provider.MediaStore.Downloads.IS_PENDING, 1)
                }
                val resolver = contentResolver
                val uri = resolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
                resolver.openOutputStream(uri)?.use { it.write(json.toByteArray()) }
                values.clear()
                values.put(android.provider.MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                uri.toString()
            } else {
                val dir = java.io.File(getExternalFilesDir(android.os.Environment.DIRECTORY_DOCUMENTS), "exports")
                dir.mkdirs()
                val file = java.io.File(dir, "ulimit-export-${System.currentTimeMillis()}.json")
                java.io.FileOutputStream(file).use { it.write(json.toByteArray()) }
                file.absolutePath
            }
        } catch (_: Exception) {
            null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == importRequestCode) {
            val result = pendingImportResult
            pendingImportResult = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                result?.success(null)
                return
            }
            result?.success(readTextFromUri(data.data!!))
        }
    }

    private fun readTextFromUri(uri: android.net.Uri): String? {
        return try {
            contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
        } catch (_: Exception) {
            null
        }
    }

    // ------------------------------------------------------------------
    // Legacy permission helpers (permissions channel)
    // ------------------------------------------------------------------

    private fun deviceAdminComponent(): android.content.ComponentName =
        android.content.ComponentName(this, UlimitDeviceAdminReceiver::class.java)

    private fun isDeviceAdminActive(): Boolean {
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as android.app.admin.DevicePolicyManager
        return dpm.isAdminActive(deviceAdminComponent())
    }

    // AccessibilityManager doesn't expose a direct "is my service
    // enabled" boolean — the documented, reliable check is comparing
    // this app's service component against the colon-separated list in
    // Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES.
    private fun isAccessibilityServiceEnabled(): Boolean {
        val expectedComponent = "$packageName/${UlimitAccessibilityService::class.java.name}"
        val enabledServices = android.provider.Settings.Secure.getString(
            contentResolver,
            android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false

        val splitter = android.text.TextUtils.SimpleStringSplitter(':')
        splitter.setString(enabledServices)
        while (splitter.hasNext()) {
            if (splitter.next().equals(expectedComponent, ignoreCase = true)) return true
        }
        return false
    }

    private fun isNotificationListenerEnabled(): Boolean {
        val enabledListeners = android.provider.Settings.Secure.getString(
            contentResolver,
            "enabled_notification_listeners"
        ) ?: return false
        android.util.Log.d(
            "UlimitBlock",
            "enabled_notification_listeners=$enabledListeners pkg=$packageName match=${enabledListeners.contains(packageName)}"
        )
        return enabledListeners.contains(packageName)
    }

    private fun isPostNotificationsGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true // no runtime prompt pre-13
        return ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.POST_NOTIFICATIONS
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    // ------------------------------------------------------------------
    // Usage access (UsageStatsManager) — special permission granted in
    // system Settings → Usage access. Provides the authoritative
    // per-app foreground times (the same data Digital Wellbeing shows),
    // used to sync/verify the app_usage table for the dashboard charts.
    // ------------------------------------------------------------------

    private fun isUsageAccessGranted(): Boolean {
        return try {
            @Suppress("DEPRECATION")
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as android.app.AppOpsManager
            @Suppress("DEPRECATION")
            val mode = appOps.checkOpNoThrow(
                android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName
            )
            mode == android.app.AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Today's per-hour foreground time for one app, as a JSON array of
     * 24 hour-buckets (index 0 = 00:00–00:59 … 23 = 23:00–23:59) with
     * each value in seconds. Uses UsageEvents (the raw event stream —
     * the authoritative per-app foreground attribution) when granted.
     */
    private fun fetchAppHourlyUsage(packageName: String): String =
        fetchAppHourlyUsageForDay(packageName, System.currentTimeMillis())

    /**
     * Per-hour foreground seconds for one app on the calendar day
     * containing [dayStartMillis] (UsageEvents retention ~7-10 days;
     * older days return zeros — DB-backed history pages cover them).
     * JSON int[24] in seconds.
     */
    private fun fetchAppHourlyUsageForDay(packageName: String, dayArg: Long): String {
        if (!isUsageAccessGranted() || packageName.isBlank()) return "[]"
        return try {
            val usm = getSystemService(Context.USAGE_STATS_SERVICE) as android.app.usage.UsageStatsManager
            val midnight = java.util.Calendar.getInstance().apply {
                timeInMillis = dayArg
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }.timeInMillis
            val dayEnd = midnight + 24 * 3600 * 1000L

            val hourly = LongArray(24)
            var lastEventAt: Long = 0
            var lastEventWasTarget = false

            val events = usm.queryEvents(midnight, dayEnd)
            val event = android.app.usage.UsageEvents.Event()
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                if (event.eventType == android.app.usage.UsageEvents.Event.ACTIVITY_RESUMED ||
                    event.eventType == android.app.usage.UsageEvents.Event.ACTIVITY_PAUSED
                ) {
                    if (lastEventWasTarget && lastEventAt > 0) {
                        val duration = (event.timeStamp - lastEventAt).coerceAtLeast(0)
                        val hourIdx = (lastEventAt - midnight) / (3600 * 1000L)
                        if (hourIdx in 0..23) hourly[hourIdx.toInt()] += duration
                    }
                    lastEventAt = event.timeStamp
                    lastEventWasTarget = event.packageName == packageName
                }
            }
            // App still in the foreground: count up to end-of-day/today cap.
            if (lastEventWasTarget && lastEventAt > 0) {
                val idx = (lastEventAt - midnight) / (3600 * 1000L)
                if (idx in 0..23) {
                    hourly[idx.toInt()] +=
                        (dayEnd.coerceAtMost(System.currentTimeMillis()) - lastEventAt).coerceAtLeast(0)
                }
            }

            val out = org.json.JSONArray()
            for (h in 0 until 24) out.put(hourly[h] / 1000)
            out.toString()
        } catch (_: Exception) {
            "[]"
        }
    }

    /**
     * Today's device-wide per-hour foreground time (all apps summed,
     * excluding this app and the launcher), as int[24] in seconds.
     * Same UsageEvents attribution as [fetchAppHourlyUsage] but without
     * the package filter — feeds the Screen Time "Today" hourly bars.
     */
    private fun fetchDeviceHourlyUsage(): String =
        fetchDayHourlyUsage(System.currentTimeMillis())

    /**
     * Per-hour foreground seconds for the calendar day containing
     * [dayStartMillis] (any day within UsageEvents retention, ~7-10
     * days on Android; older days fall back to the aggregated int[24]
     * with zeros — the DB-backed per-day history covers those). All
     * apps summed, Ulimit + launcher excluded. Returns JSON int[24].
     */
    private fun fetchDayHourlyUsage(dayStartMillis: Long): String {
        if (!isUsageAccessGranted()) return "[]"
        return try {
            val usm = getSystemService(Context.USAGE_STATS_SERVICE) as android.app.usage.UsageStatsManager
            val midnight = java.util.Calendar.getInstance().apply {
                timeInMillis = dayStartMillis
                if (dayStartMillis < System.currentTimeMillis() - (10L * 24 * 3600 * 1000)) {
                    // Historical request: strip to that day's 00:00.
                }
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }.timeInMillis

            // UsageEvents only retains ~7-10 days. For older days, the
            // query returns empty — the callers (Screen Time date strip)
            // already fall back to 'No data', and the DB-backed per-day
            // history pages show those days instead.
            val dayEnd = midnight + 24 * 3600 * 1000L
            val hourly = LongArray(24)
            var lastEventAt: Long = 0
            var lastEventWasTracked = false

            val events = usm.queryEvents(midnight, dayEnd)
            val event = android.app.usage.UsageEvents.Event()
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                if (event.eventType == android.app.usage.UsageEvents.Event.ACTIVITY_RESUMED ||
                    event.eventType == android.app.usage.UsageEvents.Event.ACTIVITY_PAUSED
                ) {
                    if (lastEventWasTracked && lastEventAt > 0) {
                        val duration = (event.timeStamp - lastEventAt).coerceAtLeast(0)
                        val hourIdx = (lastEventAt - midnight) / (3600 * 1000L)
                        if (hourIdx in 0..23) hourly[hourIdx.toInt()] += duration
                    }
                    lastEventAt = event.timeStamp
                    lastEventWasTracked =
                        event.packageName != packageName &&
                        event.packageName != "com.android.launcher" &&
                        event.packageName != "com.google.android.apps.nexuslauncher"
                }
            }
            if (lastEventWasTracked && lastEventAt > 0) {
                val idx = (lastEventAt - midnight) / (3600 * 1000L)
                if (idx in 0..23) {
                    hourly[idx.toInt()] += (dayEnd.coerceAtMost(System.currentTimeMillis()) - lastEventAt).coerceAtLeast(0)
                }
            }

            val out = org.json.JSONArray()
            for (h in 0 until 24) out.put(hourly[h] / 1000)
            out.toString()
        } catch (_: Exception) {
            "[]"
        }
    }

    /**
     * Returns per-package daily foreground times for the last [days]
     * days (including today) as a JSON array of
     * `{packageName, day (unix seconds), screenTime}` — screenTime in
     * seconds, from UsageStatsManager (authoritative, same as Digital
     * Wellbeing). Empty when the permission isn't granted.
     */
    private fun fetchDeviceUsageForDays(days: Int): String {
        if (!isUsageAccessGranted()) return "[]"
        return try {
            val usm = getSystemService(Context.USAGE_STATS_SERVICE) as android.app.usage.UsageStatsManager
            val end = java.util.Calendar.getInstance().apply {
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                add(java.util.Calendar.DAY_OF_YEAR, 1)
            }
            val start = (end.clone() as java.util.Calendar).apply {
                add(java.util.Calendar.DAY_OF_YEAR, -days)
            }

            val out = org.json.JSONArray()
            // queryUsageStats returns per-package UsageStats aggregated
            // for INTERVAL_DAILY buckets keyed by mLastTimeUsed; to get
            // per-DAY times we walk each day separately.
            for (dayOffset in 0 until days) {
                val d = (start.clone() as java.util.Calendar).apply {
                    add(java.util.Calendar.DAY_OF_YEAR, dayOffset)
                }
                val dayStart = d.timeInMillis
                val dayEnd = dayStart + (24 * 3600 * 1000L)
                val perPackage = HashMap<String, Long>()
                val stats = usm.queryUsageStats(
                    android.app.usage.UsageStatsManager.INTERVAL_DAILY,
                    dayStart, dayEnd
                )
                for (s in stats ?: continue) {
                    if (s.totalTimeInForeground <= 0) continue
                    perPackage[s.packageName] =
                        (perPackage[s.packageName] ?: 0L) + s.totalTimeInForeground
                }
                val dayUnixSeconds = dayStart / 1000
                for ((pkg, ms) in perPackage) {
                    out.put(
                        org.json.JSONObject().apply {
                            put("packageName", pkg)
                            put("day", dayUnixSeconds)
                            put("screenTime", ms / 1000)
                        }
                    )
                }
            }
            out.toString()
        } catch (_: Exception) {
            "[]"
        }
    }
}
