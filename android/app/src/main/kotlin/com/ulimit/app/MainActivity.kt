package com.ulimit.app

import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.util.Log
import android.os.Environment
import android.provider.MediaStore
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterFragmentActivity() {

    private val permissionsChannelName = "com.ulimit.app/permissions"
    private val usageEventsChannelName = "com.ulimit.app/usage_events"
    private val enforcementChannelName = "com.ulimit.app/enforcement"

    private val vpnRequestCode = 5001
    private val postNotificationsRequestCode = 5002
    private val importRequestCode = 5003

    // Kept alive across the async import flow — the channel result must
    // be completed exactly once, after the document picker returns.
    private var pendingImportResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, permissionsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAccessibilityEnabled" -> result.success(isAccessibilityServiceEnabled())
                    "openAccessibilitySettings" -> {
                        startActivity(Intent(Settings_ACTION_ACCESSIBILITY))
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
                        startActivity(Intent(Settings_ACTION_NOTIFICATION_LISTENER))
                        result.success(null)
                    }
                    "hasVpnPermission" -> result.success(android.net.VpnService.prepare(this) == null)
                    "requestVpnPermission" -> {
                        val intent = android.net.VpnService.prepare(this)
                        if (intent != null) {
                            startActivityForResult(intent, vpnRequestCode)
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
                    "exportData" -> result.success(exportData(call.arguments as? String ?: "{}"))
                    "importData" -> pendingImportResult = result
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, enforcementChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pushSnapshot" -> {
                        val obj = JSONObject()
                        val args = call.arguments
                        // Dart sends the snapshot as a Map; StandardMethodCodec
                        // already decoded it into a HashMap.
                        @Suppress("UNCHECKED_CAST")
                        putAll(obj, args as? Map<String, Any?>)
                        PolicySnapshot.write(this, obj.toString())
                        if (PolicySnapshot.isDebugBuild(this)) {
                            Log.d(
                                "UlimitBlock",
                                "snapshot pushed (${obj.toString().length} chars)"
                            )
                        }
                        // The accessibility service evaluates the new
                        // snapshot on the very next window event — nothing
                        // to notify directly.
                        result.success(null)
                    }
                    "getFilterFilePath" -> result.success(File(filesDir, "blocked_domains.txt").absolutePath)
                    "reloadDomainFilter" -> {
                        // Only meaningful (and only safe) when the VPN is
                        // already up: starting the service from a stopped
                        // state just to reload a filter file would demand
                        // a startForeground() cycle for nothing.
                        if (UlimitVpnService.isRunning) {
                            val intent = Intent(this, UlimitVpnService::class.java)
                            intent.action = UlimitVpnService.ACTION_RELOAD
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                        }
                        result.success(null)
                    }
                    "startVpn" -> {
                        val prepare = android.net.VpnService.prepare(this)
                        if (prepare != null) {
                            result.success(false)
                        } else {
                            PolicySnapshot.prefs(this).edit().putBoolean(PolicySnapshot.KEY_VPN_ENABLED, true).apply()
                            val intent = Intent(this, UlimitVpnService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        }
                    }
                    "stopVpn" -> {
                        PolicySnapshot.prefs(this).edit().putBoolean(PolicySnapshot.KEY_VPN_ENABLED, false).apply()
                        val intent = Intent(this, UlimitVpnService::class.java)
                        intent.action = UlimitVpnService.ACTION_STOP
                        startService(intent)
                        result.success(true)
                    }
                    "isVpnRunning" -> result.success(UlimitVpnService.isRunning)
                    "setDnd" -> {
                        val enabled = call.arguments as? Boolean ?: false
                        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        if (nm.isNotificationPolicyAccessGranted) {
                            nm.setInterruptionFilter(
                                if (enabled) NotificationManager.INTERRUPTION_FILTER_PRIORITY
                                else NotificationManager.INTERRUPTION_FILTER_ALL
                            )
                            PolicySnapshot.prefs(this).edit()
                                .putBoolean(PolicySnapshot.KEY_BEDTIME_ACTIVE, enabled).apply()
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "isDndAccessGranted" -> {
                        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        result.success(nm.isNotificationPolicyAccessGranted)
                    }
                    "openDndAccessSettings" -> {
                        startActivity(Intent(Settings_ACTION_NOTIFICATION_POLICY))
                        result.success(null)
                    }
                    "setBedtimeAlarms" -> {
                        val args = call.arguments as? Map<*, *>
                        val enabled = args?.get("enabled") as? Boolean ?: false
                        val start = args?.get("startTime") as? String ?: "22:30"
                        val end = args?.get("endTime") as? String ?: "06:30"
                        setBedtimeAlarms(enabled, start, end)
                        result.success(null)
                    }
                    "getInstalledApps" -> result.success(installedAppsJson())
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

    private fun putAll(target: JSONObject, map: Map<String, Any?>?) {
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
                    put(MediaStore.Downloads.DISPLAY_NAME, "ulimit-export-${System.currentTimeMillis()}.json")
                    put(MediaStore.Downloads.MIME_TYPE, "application/json")
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val resolver = contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
                resolver.openOutputStream(uri)?.use { it.write(json.toByteArray()) }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                uri.toString()
            } else {
                val dir = File(getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS), "exports")
                dir.mkdirs()
                val file = File(dir, "ulimit-export-${System.currentTimeMillis()}.json")
                FileOutputStream(file).use { it.write(json.toByteArray()) }
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

    private fun readTextFromUri(uri: Uri): String? {
        return try {
            contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
        } catch (_: Exception) {
            null
        }
    }

    // ------------------------------------------------------------------
    // Bedtime alarms — DND + snapshot flag flip at window edges, so the
    // schedule holds even when Ulimit is never opened.
    // ------------------------------------------------------------------

    private fun setBedtimeAlarms(enabled: Boolean, startTime: String, endTime: String) {
        val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val startPending = bedtimePendingIntent(BedtimeAlarmReceiver.ACTION_BEDTIME_START, 6001)
        val endPending = bedtimePendingIntent(BedtimeAlarmReceiver.ACTION_BEDTIME_END, 6002)
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

        val startMin = minutesOf(startTime)
        val endMin = minutesOf(endTime)
        val startAt = nextOccurrence(startMin)
        val endAt = nextOccurrence(endMin)

        fun schedule(triggerAt: Long, pending: PendingIntent) {
            // Exact when the OS allows it, inexact (±15 min) otherwise —
            // a bedtime boundary drifting a few minutes is acceptable,
            // failing to fire at all is not.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !am.canScheduleExactAlarms()) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            } else {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            }
        }

        schedule(startAt, startPending)
        schedule(endAt, endPending)
    }

    private fun bedtimePendingIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, BedtimeAlarmReceiver::class.java).apply { this.action = action }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(this, requestCode, intent, flags)
    }

    // ------------------------------------------------------------------
    // Installed-app catalog for the in-app pickers
    // ------------------------------------------------------------------

    private fun installedAppsJson(): List<Map<String, Any?>> {
        val pm = packageManager
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val activities = pm.queryIntentActivities(launcherIntent, 0)

        val out = mutableListOf<Map<String, Any?>>()
        for (info in activities) {
            val pkg = info.activityInfo.packageName
            if (pkg == packageName) continue
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

    private fun drawableToPng(drawable: Drawable): ByteArray {
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        val bytes = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 90, bytes)
        bitmap.recycle()
        return bytes.toByteArray()
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
        return enabledListeners.contains(packageName)
    }

    private fun isPostNotificationsGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true // no runtime prompt pre-13
        return ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.POST_NOTIFICATIONS
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
    }
}

// Settings intent action constants (kept as vals to avoid the long
// qualified names repeating in the when branches above).
private val Settings_ACTION_ACCESSIBILITY: Intent
    get() = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
private val Settings_ACTION_NOTIFICATION_LISTENER: Intent
    get() = Intent(android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
private val Settings_ACTION_NOTIFICATION_POLICY: Intent
    get() = Intent(android.provider.Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
