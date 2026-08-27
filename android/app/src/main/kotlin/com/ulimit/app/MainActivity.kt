package com.ulimit.app

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.provider.Settings
import android.text.TextUtils
import androidx.biometric.BiometricManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val permissionsChannelName = "com.ulimit.app/permissions"
    private val usageEventsChannelName = "com.ulimit.app/usage_events"

    private val vpnRequestCode = 5001
    private val postNotificationsRequestCode = 5002

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                        val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
                            putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, deviceAdminComponent())
                            putExtra(
                                DevicePolicyManager.EXTRA_ADD_EXPLANATION,
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
                    "hasVpnPermission" -> result.success(VpnService.prepare(this) == null)
                    "requestVpnPermission" -> {
                        val intent = VpnService.prepare(this)
                        if (intent != null) {
                            startActivityForResult(intent, vpnRequestCode)
                        }
                        result.success(null)
                    }
                    "isPostNotificationsGranted" -> result.success(isPostNotificationsGranted())
                    "requestPostNotifications" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                                postNotificationsRequestCode
                            )
                        }
                        result.success(null)
                    }
                    "isBiometricAvailable" -> result.success(isBiometricAvailable())
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

    private fun deviceAdminComponent(): ComponentName =
        ComponentName(this, UlimitDeviceAdminReceiver::class.java)

    private fun isDeviceAdminActive(): Boolean {
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        return dpm.isAdminActive(deviceAdminComponent())
    }

    // AccessibilityManager doesn't expose a direct "is my service
    // enabled" boolean — the documented, reliable check is comparing
    // this app's service component against the colon-separated list in
    // Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES.
    private fun isAccessibilityServiceEnabled(): Boolean {
        val expectedComponent = "$packageName/${UlimitAccessibilityService::class.java.name}"
        val enabledServices = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false

        val splitter = TextUtils.SimpleStringSplitter(':')
        splitter.setString(enabledServices)
        while (splitter.hasNext()) {
            if (splitter.next().equals(expectedComponent, ignoreCase = true)) return true
        }
        return false
    }

    private fun isNotificationListenerEnabled(): Boolean {
        val enabledListeners = Settings.Secure.getString(
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

    private fun isBiometricAvailable(): Boolean {
        val biometricManager = BiometricManager.from(this)
        return biometricManager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK) ==
            BiometricManager.BIOMETRIC_SUCCESS
    }
}
