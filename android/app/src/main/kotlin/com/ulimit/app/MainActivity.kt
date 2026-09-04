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

        // Make sure the standalone blocking service is running — the
        // snapshot persists from the previous session, so blocking is
        // live before Dart even finishes booting.
        BlockGuardService.ensureStarted(applicationContext)

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
                    "deactivateDeviceAdmin" -> {
                        try {
                            val dpm =
                                getSystemService(Context.DEVICE_POLICY_SERVICE) as android.app.admin.DevicePolicyManager
                            dpm.removeActiveAdmin(deviceAdminComponent())
                        } catch (_: Exception) {
                            // Never fatal — the channel call just reports
                            // whatever state the device ends up in.
                        }
                        result.success(null)
                    }
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
                    "openAppNotificationSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            }
                            startActivity(intent)
                        } catch (_: Exception) {
                            startActivity(Intent(Settings.ACTION_SETTINGS))
                        }
                        result.success(null)
                    }
                    "openVpnSettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                        } catch (_: Exception) {
                            startActivity(Intent(Settings.ACTION_SETTINGS))
                        }
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
                    "isOverlayGranted" -> result.success(Settings.canDrawOverlays(this))
                    "openOverlaySettings" -> {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    android.net.Uri.parse("package:$packageName")
                                )
                            )
                        } catch (_: Exception) {
                            // Some OEMs hide the per-app deep link.
                            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION))
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
                    "fetchRawUsageEventsToday" -> result.success(
                        fetchRawUsageEventsToday(call.arguments as? Int ?: 300)
                    )
                    "fetchUsageDiagnostics" -> result.success(fetchUsageDiagnostics())
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
                        !ScreenTimeFilter.isExcludedFromScreenTime(event.packageName)
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
     * Returns per-package daily foreground times as a JSON array.
     * INCREMENTAL attribution — the design that survives OEM event
     * pruning (ColorOS batches/prunes queryEvents, so a from-scratch
     * recompute loses hours): each sync consumes ONLY events newer
     * than the persisted cursor, converts RESUMED→PAUSED intervals
     * into per-day deltas, and the caller ADDS them to its database.
     * Counted events stay counted.
     *
     * Return shapes:
     *  - incremental deltas: {packageName, day, screenTime, delta:true}
     *  - first-run bootstrap (no cursor yet): a {bootstrapToday:true}
     *    marker row plus {packageName, day, screenTime} ABSOLUTE rows
     *    (closed buckets for old days, full event walk for the recent
     *    window) that Dart writes as a REPLACE baseline.
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
            val endMillis = end.timeInMillis
            val startMillis = start.timeInMillis
            val now = System.currentTimeMillis()

            // Incremental attribution state (see PolicySnapshot.KEY_*):
            // the cursor + carried open session survive process death,
            // so counted events stay counted even though ColorOS prunes
            // the queryEvents window.
            val prefs = PolicySnapshot.prefs(this)
            val cursor = prefs.getLong(PolicySnapshot.KEY_CURSOR, 0L)
            val incremental = cursor > 0L
            var openPkg = prefs.getString(PolicySnapshot.KEY_OPEN_PKG, null)
            var openSince = prefs.getLong(PolicySnapshot.KEY_OPEN_SINCE, 0L)
            var attribUpTo = prefs.getLong(PolicySnapshot.KEY_OPEN_ATTRIB, cursor)
            if (openPkg.isNullOrEmpty()) {
                openPkg = null
                attribUpTo = 0L
            } else if (attribUpTo < openSince) {
                // Defensive: never attribute from before the session began.
                attribUpTo = openSince
            }
            var newCursor = cursor

            // Days covered by the raw event stream (~7 days retention) —
            // used by the bootstrap pass only.
            val eventsStart = (endMillis - 7L * 24 * 3600 * 1000L).coerceAtLeast(startMillis)

            // dayUnixSeconds → (package → foreground millis)
            val perDay = HashMap<Long, HashMap<String, Long>>()

            val out = org.json.JSONArray()
            val scanFrom = if (incremental) {
                // Small overlap guards against clock jitter; events at
                // or before the cursor are skipped below.
                (cursor - 60_000L).coerceAtLeast(startMillis)
            } else {
                eventsStart
            }
            // Raw-event interval attribution — the system dashboard's
            // own method. One pass over all events in the window; every
            // RESUMED opens a session for its package, the next
            // PAUSED/STOPPED/SCREEN_NON_INTERACTIVE (or the next
            // RESUMED) closes it, and closed slices are split across
            // local midnights so each day gets its exact share.
            // INTERVAL_DAILY buckets are NOT used for this recent
            // window: OEMs merge multi-day buckets and the whole
            // bucket's totalTimeInForeground would land in ONE day —
            // the 7h-vs-2h bug. A still-open session counts up to NOW
            // so today's number is live, like the dashboard's current
            // app.
            if (now > scanFrom) {
                val events = usm.queryEvents(scanFrom, endMillis)
                val e = android.app.usage.UsageEvents.Event()
                // CRITICAL: continue the CARRIED session (openPkg etc.
                // above, loaded from prefs) — re-declaring these here
                // shadowed the carried state and every sync lost the
                // still-open session's head (the 3h-vs-5h undercount:
                // ColorOS emits no PAUSED for long sessions, so the
                // closing transition depends entirely on the carry).
                while (events.hasNextEvent()) {
                    events.getNextEvent(e)
                    val ts = e.timeStamp
                    // Incremental mode: events at/before the cursor were
                    // already counted on an earlier sync.
                    if (incremental && ts <= cursor) continue
                    if (ts > newCursor) newCursor = ts
                    when (e.eventType) {
                        android.app.usage.UsageEvents.Event.ACTIVITY_RESUMED -> {
                            val pkg = e.packageName ?: continue
                            val cur = openPkg
                            // A DIFFERENT app coming to the front always
                            // closes the current session.
                            if (cur != null && cur != pkg) {
                                closeSession(out, perDay, incremental, cur, openSince, attribUpTo, ts)
                                openPkg = pkg
                                openSince = ts
                                attribUpTo = ts
                            } else if (cur == null) {
                                openPkg = pkg
                                openSince = ts
                                attribUpTo = ts
                            }
                            // Same-package duplicate RESUMED: continuation,
                            // keep the original openSince/attribUpTo.
                        }
                        android.app.usage.UsageEvents.Event.ACTIVITY_PAUSED,
                        android.app.usage.UsageEvents.Event.ACTIVITY_STOPPED,
                        -> {
                            // ONLY the foreground package's own pause or
                            // stop may close its session. STOPPED events
                            // for background apps arrive seconds after a
                            // switch (and for apps that merely showed a
                            // notification) — treating them as closers
                            // chopped every session at the last switch
                            // and collapsed a day's 2h into ~30 min.
                            val cur = openPkg
                            if (cur != null && e.packageName == cur) {
                                closeSession(out, perDay, incremental, cur, openSince, attribUpTo, ts)
                                openPkg = null
                            }
                        }
                        android.app.usage.UsageEvents.Event.SCREEN_NON_INTERACTIVE -> {
                            val cur = openPkg
                            if (cur != null) {
                                closeSession(out, perDay, incremental, cur, openSince, attribUpTo, ts)
                                openPkg = null
                            }
                        }
                    }
                }
                // Still-open session: bootstrap → bucket credit to NOW;
                // incremental → emit the growth since attribUpTo as a
                // delta and carry the session forward (attribUpTo=NOW).
                val pkg = openPkg
                if (pkg != null) {
                    if (incremental) {
                        if (now > attribUpTo) emitDelta(out, pkg, attribUpTo, now)
                        attribUpTo = now
                    } else {
                        addForegroundInterval(perDay, pkg, openSince, now)
                    }
                }
            }

            // Days older than the event-retention window: CLOSED
            // INTERVAL_DAILY buckets that sit entirely inside their day.
            // A bucket spanning days can never be split without raw
            // events, and dropping it whole into one day is exactly the
            // inflation this rewrite kills — so spanning buckets are
            // skipped, never assigned. BOOTSTRAP ONLY — incremental
            // syncs never re-read buckets (they'd double-count).
            if (!incremental && startMillis < eventsStart) {
                for (dayStart in startMillis until eventsStart step (24 * 3600 * 1000L)) {
                    val dayEnd = dayStart + (24 * 3600 * 1000L)
                    val dayUnixSeconds = dayStart / 1000
                    val perPackage = perDay[dayUnixSeconds] ?: HashMap()
                    val stats = usm.queryUsageStats(
                        android.app.usage.UsageStatsManager.INTERVAL_DAILY,
                        dayStart, dayEnd
                    ) ?: continue
                    for (s in stats) {
                        if (s.totalTimeInForeground <= 0) continue
                        if (s.firstTimeStamp < dayStart || s.lastTimeStamp > dayEnd) continue
                        perPackage[s.packageName] =
                            (perPackage[s.packageName] ?: 0L) + s.totalTimeInForeground
                    }
                    if (perPackage.isNotEmpty()) perDay[dayUnixSeconds] = perPackage
                }
            }

            // Bootstrap: emit the recompute as ABSOLUTE rows plus the
            // marker telling Dart to REPLACE. Incremental: rows are
            // already emitted as deltas inside the loop above.
            if (!incremental) {
                for ((dayUnixSeconds, perPackage) in perDay) {
                    for ((pkg, ms) in perPackage) {
                        if (ms <= 0) continue
                        out.put(
                            org.json.JSONObject().apply {
                                put("packageName", pkg)
                                put("day", dayUnixSeconds)
                                put("screenTime", ms / 1000)
                            }
                        )
                    }
                }
                out.put(org.json.JSONObject().apply {
                    put("bootstrapToday", true)
                    put("day", 0)
                    put("screenTime", 0)
                })
            }

            // Persist cursor + open-session state so the next sync
            // consumes only events newer than newCursor and the open
            // session's head is never lost (even across process death).
            prefs.edit()
                .putLong(PolicySnapshot.KEY_CURSOR, newCursor)
                .putString(PolicySnapshot.KEY_OPEN_PKG, openPkg ?: "")
                .putLong(PolicySnapshot.KEY_OPEN_SINCE, if (openPkg != null) openSince else 0L)
                .putLong(PolicySnapshot.KEY_OPEN_ATTRIB, attribUpTo)
                .apply()

            out.toString()
        } catch (_: Exception) {
            "[]"
        }
    }

    /** Closes one foreground session in the mode-appropriate shape:
     *  incremental → emit an ADD delta row; bootstrap → credit the
     *  perDay buckets for the full-recompute baseline. */
    private fun closeSession(
        out: org.json.JSONArray,
        perDay: HashMap<Long, HashMap<String, Long>>,
        incremental: Boolean,
        pkg: String,
        openSince: Long,
        attribUpTo: Long,
        closeAt: Long,
    ) {
        if (incremental) {
            if (closeAt > attribUpTo) emitDelta(out, pkg, attribUpTo, closeAt)
        } else {
            addForegroundInterval(perDay, pkg, openSince, closeAt)
        }
    }

    /** Emits one incremental delta row for [pkg] covering
     *  [from, to), split at local midnights, flagged delta=true so
     *  Dart ADDS it instead of replacing. */
    private fun emitDelta(out: org.json.JSONArray, pkg: String, from: Long, to: Long) {
        var cursorMs = from
        while (cursorMs < to) {
            val cal = java.util.Calendar.getInstance().apply {
                timeInMillis = cursorMs
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
                add(java.util.Calendar.DAY_OF_YEAR, 1)
            }
            val dayEnd = cal.timeInMillis
            val sliceEnd = minOf(to, dayEnd)
            val midnight = java.util.Calendar.getInstance().apply {
                timeInMillis = sliceEnd - 1
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }.timeInMillis
            out.put(
                org.json.JSONObject().apply {
                    put("packageName", pkg)
                    put("day", midnight / 1000)
                    put("screenTime", (sliceEnd - cursorMs) / 1000)
                    put("delta", true)
                }
            )
            cursorMs = sliceEnd
        }
    }

    /** Adds [from, to) foreground millis for [pkg] into [perDay],
     *  splitting the interval at every local midnight so each day gets
     *  exactly its own share — the dashboard's day split. */
    private fun addForegroundInterval(
        perDay: HashMap<Long, HashMap<String, Long>>,
        pkg: String,
        from: Long,
        to: Long,
    ) {
        if (to <= from) return
        var cursor = from
        while (cursor < to) {
            val cal = java.util.Calendar.getInstance().apply {
                timeInMillis = cursor
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
                add(java.util.Calendar.DAY_OF_YEAR, 1)
            }
            val dayEnd = cal.timeInMillis
            val sliceEnd = minOf(to, dayEnd)
            // Local midnight immediately before sliceEnd, in unix
            // seconds — the day the slice belongs to (sliceEnd-1 is
            // inside the day even when sliceEnd lands on midnight).
            val midnight = java.util.Calendar.getInstance().apply {
                timeInMillis = sliceEnd - 1
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }.timeInMillis
            val dayUnixSeconds = midnight / 1000
            val bucket = perDay.getOrPut(dayUnixSeconds) { HashMap() }
            bucket[pkg] = (bucket[pkg] ?: 0L) + (sliceEnd - cursor)
            cursor = sliceEnd
        }
    }

    // ------------------------------------------------------------------
    // Screen-time diagnostics (the copyable report cross-checks our
    // numbers against the OS raw event stream).
    // ------------------------------------------------------------------

    /**
     * Raw UsageEvents dump for today (ACTIVITY_RESUMED / PAUSED /
     * SCREEN_INTERACTIVE / NON_INTERACTIVE), capped to the last [limit]
     * events: [{t, type, pkg}]. Lets the diagnostics report verify the
     * OS itself saw every transition our tracker claims to have seen.
     */
    private fun fetchRawUsageEventsToday(limit: Int): String {
        if (!isUsageAccessGranted()) return "[]"
        return try {
            val usm = getSystemService(Context.USAGE_STATS_SERVICE) as android.app.usage.UsageStatsManager
            val midnight = java.util.Calendar.getInstance().apply {
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }.timeInMillis
            val out = org.json.JSONArray()
            val events = usm.queryEvents(midnight, System.currentTimeMillis())
            val event = android.app.usage.UsageEvents.Event()
            val all = ArrayList<Triple<Long, Int, String>>()
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                when (event.eventType) {
                    android.app.usage.UsageEvents.Event.ACTIVITY_RESUMED,
                    android.app.usage.UsageEvents.Event.ACTIVITY_PAUSED,
                    android.app.usage.UsageEvents.Event.SCREEN_INTERACTIVE,
                    android.app.usage.UsageEvents.Event.SCREEN_NON_INTERACTIVE ->
                        all.add(Triple(event.timeStamp, event.eventType, event.packageName ?: "?"))
                }
            }
            val from = (all.size - limit).coerceAtLeast(0)
            for (i in from until all.size) {
                val (t, type, pkg) = all[i]
                out.put(
                    org.json.JSONObject().apply {
                        put("t", t)
                        put("type", type)
                        put("pkg", pkg)
                    }
                )
            }
            out.toString()
        } catch (_: Exception) {
            "[]"
        }
    }

    /**
     * Diagnostic counters from the native layer: whether the screen
     * on/off bridge has fired, when the accessibility service last saw
     * an event, and whether usage access is granted. Read by the
     * copyable screen-time report to answer "is the feature ON and
     * actually WORKING?".
     */
    private fun fetchUsageDiagnostics(): String {
        return try {
            val version = try {
                packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
            } catch (_: Exception) {
                "?"
            }
            val snapshot = PolicySnapshot.read(this)
            val focus = snapshot?.focus
            org.json.JSONObject().apply {
                put("usageAccessGranted", isUsageAccessGranted())
                put("accessibilityConnected", UlimitAccessibilityService.instance != null)
                put("lastAccessibilityEventAt", DiagnosticsMarkers.lastAccessibilityEventAt)
                put("lastScreenOffAt", DiagnosticsMarkers.lastScreenOffAt)
                put("lastUnlockAt", DiagnosticsMarkers.lastUnlockAt)
                put("now", System.currentTimeMillis())
                put("device", "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
                put("sdk", android.os.Build.VERSION.SDK_INT)
                put("appVersion", version)
                // --- Doomscroll engine breadcrumbs -------------------
                put("scrollEventsSeen", DiagnosticsMarkers.scrollEventsSeen)
                put("lastScrollEventAt", DiagnosticsMarkers.lastScrollEventAt)
                put("sectionScrollEventsSeen", DiagnosticsMarkers.sectionScrollEventsSeen)
                put("lastSectionScrollAt", DiagnosticsMarkers.lastSectionScrollAt)
                put("lastSectionScrollPkg", DiagnosticsMarkers.lastSectionScrollPkg)
                put("feedScans", DiagnosticsMarkers.feedScans)
                put("lastFeedScanAt", DiagnosticsMarkers.lastFeedScanAt)
                put("lastFeedScanPkg", DiagnosticsMarkers.lastFeedScanPkg)
                put("feedSurfaceHits", DiagnosticsMarkers.feedSurfaceHits)
                put("lastFeedSurfaceHitAt", DiagnosticsMarkers.lastFeedSurfaceHitAt)
                put("feedEjects", DiagnosticsMarkers.feedEjects)
                put("lastFeedEjectAt", DiagnosticsMarkers.lastFeedEjectAt)
                put("lastFeedEjectPkg", DiagnosticsMarkers.lastFeedEjectPkg)
                put("doomOpens", DiagnosticsMarkers.doomOpens)
                put("lastDoomOpenAt", DiagnosticsMarkers.lastDoomOpenAt)
                put("lastDoomOpenPkg", DiagnosticsMarkers.lastDoomOpenPkg)
                put("scrollSessions", DiagnosticsMarkers.scrollSessions)
                put("lastScrollSessionAt", DiagnosticsMarkers.lastScrollSessionAt)
                put("doomOpenViaScroll", DiagnosticsMarkers.doomOpenViaScroll)
                put("serviceInfoForced", DiagnosticsMarkers.serviceInfoForced)
                put("gapDiscards", DiagnosticsMarkers.gapDiscards)
                // --- Focus Session pill (status bar) -----------------
                put("focusPillRunning", FocusIndicatorService.isRunning)
                put("focusPillStartError", FocusIndicatorService.lastStartError ?: "")
                put("notificationsEnabled", FocusIndicatorService.areNotificationsEnabled(this@MainActivity))
                put("focusPillChannel", FocusIndicatorService.channelImportance(this@MainActivity))
                // --- Website blocking (no-VPN chain) -----------------
                val domainsFile = java.io.File(filesDir, "blocked_domains.txt")
                put("domainsFileExists", domainsFile.exists())
                put(
                    "domainsCount",
                    if (domainsFile.exists()) {
                        domainsFile.readLines().count { it.isNotBlank() }
                    } else 0
                )
                put("websiteScans", BrowserScanMarkers.scans)
                put("lastWebsiteScanAt", BrowserScanMarkers.lastScanAt)
                put("lastWebsiteScanPkg", BrowserScanMarkers.lastScanPkg)
                put("websiteBlocks", BrowserScanMarkers.blocks)
                put("lastWebsiteBlockAt", BrowserScanMarkers.lastBlockAt)
                put("lastWebsiteBlockDomain", BrowserScanMarkers.lastBlockDomain)
                put("vpnRunning", UlimitVpnService.isRunning)
                val snap = PolicySnapshot.read(this@MainActivity)
                put(
                    "internetBlocksCount",
                    snap?.internetBlocks?.size ?: 0
                )
                put("adultFilterEnabled", snap?.adultFilterEnabled == true)
                put(
                    "browserPackages",
                    org.json.JSONArray().apply {
                        for (p in snap?.browserPackages ?: emptyList()) put(p)
                    }
                )
                // Incremental attribution cursor + carried session.
                val prefsD = PolicySnapshot.prefs(this@MainActivity)
                put("usageCursorAt", prefsD.getLong(PolicySnapshot.KEY_CURSOR, 0L))
                put("usageOpenPkg", prefsD.getString(PolicySnapshot.KEY_OPEN_PKG, "") ?: "")
                // Snapshot state the detector evaluates against.
                put("snapshotPresent", snapshot != null)
                put("focusDoomscrollFlag", focus?.blockDoomscroll == true)
                put("focusUntilMillis", focus?.untilMillis ?: 0)
                put("doomFeeds", org.json.JSONObject().apply {
                    for ((k, v) in snapshot?.doomscrollFeeds ?: emptyMap()) put(k, v)
                })
                put("doomSection", org.json.JSONArray().apply {
                    for (p in snapshot?.doomscrollSection ?: emptyList()) put(p)
                })
                put("doomNativeOpens", org.json.JSONObject().apply {
                    for ((k, v) in PolicySnapshot.doomscrollCounts(this@MainActivity)) put(k, v)
                })
            }.toString()
        } catch (_: Exception) {
            "{}"
        }
    }
}
