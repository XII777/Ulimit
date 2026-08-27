#!/usr/bin/env bash
# Adds real permission handling (Accessibility, Device Admin, VPN,
# Notification Listener, Biometric) + wires Home screen to live
# Drift-backed data instead of hardcoded mockup values.
# Applies, commits, pushes, then deletes itself.
set -e

if [ ! -f pubspec.yaml ]; then
  echo "Run this from inside your repo root (where pubspec.yaml lives)."
  exit 1
fi

mkdir -p "android/app"
cat > "android/app/build.gradle" << 'PATCH_EOF'
plugins {
    id "com.android.application"
    id "kotlin-android"
    id "dev.flutter.flutter-gradle-plugin"
}

android {
    namespace "com.ulimit.app"
    compileSdk 34
    ndkVersion flutter.ndkVersion

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17
    }

    sourceSets {
        main.java.srcDirs += "src/main/kotlin"
    }

    defaultConfig {
        applicationId "com.ulimit.app"
        // sqlite3_flutter_libs and drift both work fine from API 23+;
        // going lower buys negligible reach in 2026 and complicates the
        // AccessibilityService APIs used above.
        minSdk 23
        targetSdk 34
        versionCode flutter.versionCode
        versionName flutter.versionName
    }

    buildTypes {
        release {
            // No real signing config wired here — CI's `flutter build apk
            // --release` produces an unsigned/debug-signed artifact for
            // sideload testing. Wire a proper keystore + signingConfig
            // before a Play Store submission.
            signingConfig signingConfigs.debug
            minifyEnabled false
            shrinkResources false
        }
    }
}

flutter {
    source "../.."
}

dependencies {
    // Biometric availability check (BiometricManager) used in
    // MainActivity.kt's isBiometricAvailable().
    implementation "androidx.biometric:biometric:1.1.0"
    implementation "androidx.core:core-ktx:1.13.1"
}
PATCH_EOF

mkdir -p "android/app/src/main"
cat > "android/app/src/main/AndroidManifest.xml" << 'PATCH_EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <!-- Core -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />

    <!-- Android 13+ runtime permission for notification batching/muting -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

    <!-- Needed to enumerate installed apps for the app-picker in
         Limits/Blocking screens. Google Play requires a declared-use
         justification form for this on submission — it's granted at
         install time (normal permission), not a runtime prompt. -->
    <uses-permission android:name="android.permission.QUERY_ALL_PACKAGES"
        tools:ignore="QueryAllPackagesPermission" />

    <application
        android:label="Ulimit"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:taskAffinity=""
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <meta-data
                android:name="io.flutter.embedding.android.NormalTheme"
                android:resource="@style/NormalTheme" />
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />

        <!-- Accessibility Service — the core enforcement engine. Detects
             foreground app changes (usage tracking, limit enforcement)
             and draws the blocking overlay directly. -->
        <service
            android:name=".UlimitAccessibilityService"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE"
            android:exported="false">
            <intent-filter>
                <action android:name="android.accessibilityservice.AccessibilityService" />
            </intent-filter>
            <meta-data
                android:name="android.accessibilityservice"
                android:resource="@xml/accessibility_service_config" />
        </service>

        <!-- Device Admin — blocks uninstall/force-stop as a bypass route. -->
        <receiver
            android:name=".UlimitDeviceAdminReceiver"
            android:permission="android.permission.BIND_DEVICE_ADMIN"
            android:exported="true">
            <meta-data
                android:name="android.app.device_admin"
                android:resource="@xml/device_admin_receiver" />
            <intent-filter>
                <action android:name="android.app.action.DEVICE_ADMIN_ENABLED" />
            </intent-filter>
        </receiver>

        <!-- Notification Listener — powers notification batching/muting
             during focus sessions and Bedtime mode. -->
        <service
            android:name=".UlimitNotificationListenerService"
            android:label="Ulimit"
            android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE"
            android:exported="false">
            <intent-filter>
                <action android:name="android.service.notification.NotificationListenerService" />
            </intent-filter>
        </service>

        <!-- Local VPN — per-app internet blocking and website/domain
             filtering. Traffic never leaves the device; see UlimitVpnService. -->
        <service
            android:name=".UlimitVpnService"
            android:permission="android.permission.BIND_VPN_SERVICE"
            android:exported="false">
            <intent-filter>
                <action android:name="android.net.VpnService" />
            </intent-filter>
        </service>

    </application>

    <queries>
        <intent>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LAUNCHER" />
        </intent>
    </queries>
</manifest>
PATCH_EOF

mkdir -p "android/app/src/main/kotlin/com/ulimit/app"
cat > "android/app/src/main/kotlin/com/ulimit/app/MainActivity.kt" << 'PATCH_EOF'
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
PATCH_EOF

mkdir -p "android/app/src/main/kotlin/com/ulimit/app"
cat > "android/app/src/main/kotlin/com/ulimit/app/UlimitAccessibilityService.kt" << 'PATCH_EOF'
package com.ulimit.app

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

/// The actual data source behind every usage number in the app. Fires
/// on every window-state change (the OS's signal for "a different app
/// (or a different screen within one) is now in front"), and forwards
/// the package name + timestamp to Dart via [UsageEventBridge].
///
/// Deliberately thin: all the actual logic (attributing elapsed time,
/// writing to the DB, detecting pickups, deciding when to show the
/// blocking overlay) lives in Dart (UsageTracker) rather than here.
/// Keeping the native side to "detect and forward" means the
/// enforcement logic is testable and iterable in Dart without a
/// Gradle rebuild for every tweak.
class UlimitAccessibilityService : AccessibilityService() {

    private var lastPackageName: String? = null

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return

        val packageName = event.packageName?.toString() ?: return

        // The system UI / our own app switching to itself isn't a real
        // "the user picked up a different app" transition worth logging.
        if (packageName == this.packageName) return
        if (packageName == lastPackageName) return

        lastPackageName = packageName
        UsageEventBridge.emit(packageName, System.currentTimeMillis())
    }

    override fun onInterrupt() {
        // Required override; nothing to clean up — no ongoing async work
        // is held directly by this service.
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        lastPackageName = null
    }
}
PATCH_EOF

mkdir -p "android/app/src/main/kotlin/com/ulimit/app"
cat > "android/app/src/main/kotlin/com/ulimit/app/UlimitDeviceAdminReceiver.kt" << 'PATCH_EOF'
package com.ulimit.app

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/// No custom policy enforcement — being an active admin at all is what
/// blocks a casual uninstall/force-stop. onEnabled/onDisabled are
/// logged, not acted on, since Invincible Mode's actual "don't let the
/// user undo this" logic lives in Dart against the RestrictionGroups
/// table, not here.
class UlimitDeviceAdminReceiver : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        super.onEnabled(context, intent)
        Log.i("Ulimit", "Device admin enabled")
    }

    override fun onDisabled(context: Context, intent: Intent) {
        super.onDisabled(context, intent)
        Log.i("Ulimit", "Device admin disabled")
    }
}
PATCH_EOF

mkdir -p "android/app/src/main/kotlin/com/ulimit/app"
cat > "android/app/src/main/kotlin/com/ulimit/app/UlimitNotificationListenerService.kt" << 'PATCH_EOF'
package com.ulimit.app

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/// Grants the permission surface the onboarding screen checks against
/// (BIND_NOTIFICATION_LISTENER_SERVICE requires an actual declared
/// service, not just a manifest permission). The real batching/muting
/// policy — hold, silence, or release based on Bedtime/Focus state — is
/// intentionally not implemented yet; wiring it needs the
/// RestrictionGroups + BedtimeSchedule state to be readable from native
/// code, which is the next slice of this feature, not this one.
class UlimitNotificationListenerService : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        // Intentionally empty for now — see class doc.
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        // Intentionally empty for now — see class doc.
    }
}
PATCH_EOF

mkdir -p "android/app/src/main/kotlin/com/ulimit/app"
cat > "android/app/src/main/kotlin/com/ulimit/app/UlimitVpnService.kt" << 'PATCH_EOF'
package com.ulimit.app

import android.net.VpnService

/// Grants the permission surface the onboarding screen checks
/// (VpnService.prepare/hasVpnPermission) and gives the system something
/// real to bind to. The actual local-filtering logic — establishing the
/// TUN interface, routing selected apps' traffic through it, DNS-based
/// domain blocking — is a substantial feature on its own (see the
/// Internet & Sites mockup) and is the next slice, not this one.
///
/// Critically: even once implemented, this stays a *local* VPN — no
/// remote server, no traffic leaving the device. VpnService is Android's
/// sanctioned API for exactly this on-device-filter pattern; it's not
/// being used as a proxy.
class UlimitVpnService : VpnService()
PATCH_EOF

mkdir -p "android/app/src/main/kotlin/com/ulimit/app"
cat > "android/app/src/main/kotlin/com/ulimit/app/UsageEventBridge.kt" << 'PATCH_EOF'
package com.ulimit.app

import io.flutter.plugin.common.EventChannel

/// Simple in-process bridge. UlimitAccessibilityService runs in the same
/// process as the Flutter engine (no `android:process` set in the
/// manifest), so a static sink reference is sufficient — this avoids
/// standing up a full plugin/AIDL layer for what's fundamentally a
/// same-process callback.
///
/// [sink] is null whenever Dart isn't listening (app not running, or
/// between hot restarts) — [emit] guards against that so the service
/// never crashes trying to push into a torn-down channel.
object UsageEventBridge {
    var sink: EventChannel.EventSink? = null

    fun emit(packageName: String, timestampMillis: Long) {
        sink?.success(
            mapOf(
                "package" to packageName,
                "timestamp" to timestampMillis
            )
        )
    }
}
PATCH_EOF

mkdir -p "android/app/src/main/res/drawable"
cat > "android/app/src/main/res/drawable/launch_background.xml" << 'PATCH_EOF'
<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@color/launch_background_color" />
</layer-list>
PATCH_EOF

mkdir -p "android/app/src/main/res/values"
cat > "android/app/src/main/res/values/colors.xml" << 'PATCH_EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Matches AppColors.bg (#0F1116) exactly, so the native splash
         and the Flutter-rendered first frame are indistinguishable. -->
    <color name="launch_background_color">#0F1116</color>
</resources>
PATCH_EOF

mkdir -p "android/app/src/main/res/values"
cat > "android/app/src/main/res/values/strings.xml" << 'PATCH_EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">Ulimit</string>
    <string name="accessibility_service_description">Lets Ulimit detect app usage, enforce limits, and show the block screen — this is the core engine behind the app and never leaves your device.</string>
</resources>
PATCH_EOF

mkdir -p "android/app/src/main/res/values"
cat > "android/app/src/main/res/values/styles.xml" << 'PATCH_EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Shown while Flutter initializes; matches the app's dark theme
         so there's no white flash before the Dart-side theme takes over. -->
    <style name="LaunchTheme" parent="@android:style/Theme.Black.NoTitleBar">
        <item name="android:windowBackground">@drawable/launch_background</item>
    </style>

    <style name="NormalTheme" parent="@android:style/Theme.Black.NoTitleBar">
        <item name="android:windowBackground">?android:colorBackground</item>
    </style>
</resources>
PATCH_EOF

mkdir -p "android/app/src/main/res/xml"
cat > "android/app/src/main/res/xml/accessibility_service_config.xml" << 'PATCH_EOF'
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeWindowStateChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagDefault"
    android:canRetrieveWindowContent="true"
    android:notificationTimeout="100"
    android:description="@string/accessibility_service_description" />
PATCH_EOF

mkdir -p "android/app/src/main/res/xml"
cat > "android/app/src/main/res/xml/device_admin_receiver.xml" << 'PATCH_EOF'
<?xml version="1.0" encoding="utf-8"?>
<device-admin xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-policies>
        <!-- limit-password is the minimal policy needed so this XML is
             valid (Android requires at least one declared policy). It's
             never actually enforced — Ulimit doesn't set password rules.
             Device Admin status alone is what blocks a casual uninstall
             or force-stop without first deactivating admin in Settings. -->
        <limit-password />
    </uses-policies>
</device-admin>
PATCH_EOF

mkdir -p "android"
cat > "android/gradle.properties" << 'PATCH_EOF'
org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=2G
android.useAndroidX=true
android.enableJetifier=true
PATCH_EOF

mkdir -p "android"
cat > "android/settings.gradle" << 'PATCH_EOF'
pluginManagement {
    def flutterSdkPath = {
        def properties = new Properties()
        file("local.properties").withInputStream { properties.load(it) }
        def flutterSdkPath = properties.getProperty("flutter.sdk")
        assert flutterSdkPath != null, "flutter.sdk not set in local.properties"
        return flutterSdkPath
    }()

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id "dev.flutter.flutter-plugin-loader" version "1.0.0"
    id "com.android.application" version "8.3.2" apply false
    id "org.jetbrains.kotlin.android" version "1.9.22" apply false
}

include ":app"
PATCH_EOF

mkdir -p "lib/core/native"
cat > "lib/core/native/permissions_channel.dart" << 'PATCH_EOF'
import 'package:flutter/services.dart';

/// Thin wrapper around the native MethodChannel. Every method here maps
/// 1:1 to a `when` branch in MainActivity.kt's onMethodCall — keep them
/// in sync if you add a new permission.
///
/// Android does not let an app silently grant Accessibility Service or
/// Notification Listener access — those two always require the user to
/// flip a toggle in system Settings, so their "request" methods open
/// Settings rather than showing an in-app dialog. Device Admin, VPN, and
/// POST_NOTIFICATIONS *do* support an in-app system dialog, so those
/// request methods trigger one directly.
class NativePermissions {
  NativePermissions._();
  static const _channel = MethodChannel('com.ulimit.app/permissions');

  static Future<bool> isAccessibilityEnabled() async {
    return await _channel.invokeMethod<bool>('isAccessibilityEnabled') ?? false;
  }

  static Future<void> openAccessibilitySettings() =>
      _channel.invokeMethod('openAccessibilitySettings');

  static Future<bool> isDeviceAdminActive() async {
    return await _channel.invokeMethod<bool>('isDeviceAdminActive') ?? false;
  }

  static Future<void> requestDeviceAdmin() => _channel.invokeMethod('requestDeviceAdmin');

  static Future<bool> isNotificationListenerEnabled() async {
    return await _channel.invokeMethod<bool>('isNotificationListenerEnabled') ?? false;
  }

  static Future<void> openNotificationListenerSettings() =>
      _channel.invokeMethod('openNotificationListenerSettings');

  static Future<bool> hasVpnPermission() async {
    return await _channel.invokeMethod<bool>('hasVpnPermission') ?? false;
  }

  static Future<void> requestVpnPermission() => _channel.invokeMethod('requestVpnPermission');

  static Future<bool> isPostNotificationsGranted() async {
    return await _channel.invokeMethod<bool>('isPostNotificationsGranted') ?? false;
  }

  static Future<void> requestPostNotifications() =>
      _channel.invokeMethod('requestPostNotifications');

  static Future<bool> isBiometricAvailable() async {
    return await _channel.invokeMethod<bool>('isBiometricAvailable') ?? false;
  }
}
PATCH_EOF

mkdir -p "lib/core/native"
cat > "lib/core/native/usage_events_channel.dart" << 'PATCH_EOF'
import 'package:flutter/services.dart';

/// One real event per foreground-app transition, pushed from
/// UlimitAccessibilityService.kt. This is the actual data source behind
/// every "usage" number in the app — nothing here is synthetic.
class ForegroundEvent {
  ForegroundEvent({required this.packageName, required this.timestampMillis});

  factory ForegroundEvent.fromMap(Map<dynamic, dynamic> map) => ForegroundEvent(
        packageName: map['package'] as String,
        timestampMillis: map['timestamp'] as int,
      );

  final String packageName;
  final int timestampMillis;
}

class UsageEventsChannel {
  UsageEventsChannel._();
  static const _events = EventChannel('com.ulimit.app/usage_events');

  static Stream<ForegroundEvent> get stream => _events
      .receiveBroadcastStream()
      .map((raw) => ForegroundEvent.fromMap(raw as Map<dynamic, dynamic>));
}
PATCH_EOF

mkdir -p "lib/data/db"
cat > "lib/data/db/app_database.dart" << 'PATCH_EOF'
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'tables.dart';

part 'app_database.g.dart'; // generated by build_runner

@DriftDatabase(tables: [
  Profile,
  FocusSessions,
  AppUsage,
  RestrictionGroups,
  RestrictionGroupApps,
  BlockedApps,
  BedtimeSchedule,
  ScoreLog,
  EmergencyUnlocks,
  PickupsLog,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  // Migrations start here once schemaVersion > 1. Left explicit (rather
  // than "just delete and recreate") because this is local user data —
  // wiping someone's focus history on an app update is not acceptable.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async => m.createAll(),
      );
}

LazyDatabase _openConnection() {
  // LazyDatabase defers opening the file until first query, off the
  // app's cold-start critical path — avoids a startup jank spike on
  // low-end devices where disk I/O + SQLite init can take 30-80ms.
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'ulimit.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
PATCH_EOF

mkdir -p "lib/data/db"
cat > "lib/data/db/tables.dart" << 'PATCH_EOF'
import 'package:drift/drift.dart';

/// One local profile row (singleton — no accounts). Display name, photo
/// path, and theme preference for the share card / settings.
class Profile extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get displayName => text().withDefault(const Constant('You'))();
  TextColumn get photoPath => text().nullable()();
  TextColumn get themeId => text().withDefault(const Constant('violet'))();
  // Daily screen-time budget in minutes, used by the Home ring and the
  // score formula's screen-time component. Configurable in Settings;
  // defaults to 4h for a fresh install so the ring has something
  // meaningful to show before the user sets their own number.
  IntColumn get dailyBudgetMinutes => integer().withDefault(const Constant(240))();
}

class FocusSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get label => text()(); // "Deep Work", "Study"...
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get plannedSeconds => integer()();
  BoolColumn get invincible => boolean().withDefault(const Constant(false))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
}

/// One row per tracked package per day. Aggregated in-memory for
/// weekly/monthly views rather than maintaining separate rollup tables —
/// at this data volume (a few hundred rows/month/device) a SUM query is
/// cheaper than the bookkeeping a materialized rollup would need.
class AppUsage extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get packageName => text()();
  DateTimeColumn get day => dateTime()(); // truncated to midnight
  IntColumn get foregroundSeconds => integer().withDefault(const Constant(0))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {packageName, day}
      ];
}

class RestrictionGroups extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get dailyLimitSeconds => integer()();
  BoolColumn get invincible => boolean().withDefault(const Constant(false))();
}

class RestrictionGroupApps extends Table {
  IntColumn get groupId => integer().references(RestrictionGroups, #id)();
  TextColumn get packageName => text()();

  @override
  Set<Column> get primaryKey => {groupId, packageName};
}

class BlockedApps extends Table {
  TextColumn get packageName => text()();
  TextColumn get scheduleStart => text().nullable()(); // "HH:mm" or null = all day
  TextColumn get scheduleEnd => text().nullable()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {packageName};
}

class BedtimeSchedule extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get startTime => text()(); // "22:30"
  TextColumn get endTime => text()(); // "06:30"
  BoolColumn get dndEnabled => boolean().withDefault(const Constant(true))();
  BoolColumn get pauseApps => boolean().withDefault(const Constant(true))();
  BoolColumn get grayscale => boolean().withDefault(const Constant(false))();
}

/// Daily snapshot of the Limit score components, so the score is
/// recomputable/auditable rather than a single mutated integer —
/// important once "decay" or recalculation logic changes later.
class ScoreLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get day => dateTime()();
  RealColumn get screenTimeComponent => real()();
  RealColumn get focusConsistencyComponent => real()();
  RealColumn get streakComponent => real()();
  RealColumn get limitsKeptComponent => real()();
  IntColumn get totalScore => integer()();
}

class EmergencyUnlocks extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get usedAt => dateTime()();
  TextColumn get packageName => text()();
  IntColumn get grantedSeconds => integer()();
}

/// One row per day. Incremented every time the AccessibilityService
/// reports a foreground-app transition — this is what "Pickups / day"
/// on Home actually measures. Approximate by nature (a true "unlock"
/// signal would need ACTION_USER_PRESENT from a separate BroadcastReceiver,
/// which is a reasonable v2 addition), but every foreground switch is a
/// real, on-device event, not a guess.
class PickupsLog extends Table {
  DateTimeColumn get day => dateTime()(); // truncated to midnight

  IntColumn get count => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {day};
}
PATCH_EOF

mkdir -p "lib/data"
cat > "lib/data/home_data_providers.dart" << 'PATCH_EOF'
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'db/app_database.dart';
import 'providers.dart';

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _daysAgo(int n) => _startOfDay(DateTime.now().subtract(Duration(days: n)));

/// The user's configured daily budget, in minutes. Falls back to the
/// schema default (240) via Drift's own default value if no Profile
/// row exists yet — a fresh install still gets a sane ring.
final dailyBudgetProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.profile).watchSingleOrNull().map((row) => row?.dailyBudgetMinutes ?? 240);
});

/// Last 7 days of total screen time, oldest→newest, in hours — feeds
/// the weekly trend chart directly. Real query, not a fixture array.
final weeklyScreenTimeHoursProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.appUsage)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final byDay = <DateTime, int>{};
    for (final r in rows) {
      byDay.update(r.day, (v) => v + r.foregroundSeconds, ifAbsent: () => r.foregroundSeconds);
    }
    return List.generate(7, (i) {
      final day = _daysAgo(6 - i);
      final seconds = byDay[day] ?? 0;
      return seconds / 3600.0;
    });
  });
});

/// Daily focus-session totals for the last 7 days, oldest→newest, in
/// hours — mirrors weeklyScreenTimeHoursProvider's shape so both feed
/// the same chart widgets consistently.
final weeklyFocusHoursByDayProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.focusSessions)
    ..where((t) => t.startedAt.isBiggerOrEqualValue(start) & t.completed.equals(true));

  return query.watch().map((rows) {
    final byDay = <DateTime, int>{};
    for (final s in rows) {
      if (s.endedAt == null) continue;
      final day = _startOfDay(s.startedAt);
      final seconds = s.endedAt!.difference(s.startedAt).inSeconds;
      byDay.update(day, (v) => v + seconds, ifAbsent: () => seconds);
    }
    return List.generate(7, (i) {
      final day = _daysAgo(6 - i);
      return (byDay[day] ?? 0) / 3600.0;
    });
  });
});

/// Total completed focus-session time this week, in seconds.
final weeklyFocusSecondsProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.focusSessions)
    ..where((t) => t.startedAt.isBiggerOrEqualValue(start) & t.completed.equals(true));

  return query.watch().map((rows) => rows.fold<int>(0, (sum, s) {
        if (s.endedAt == null) return sum;
        return sum + s.endedAt!.difference(s.startedAt).inSeconds;
      }));
});

/// Daily pickup counts for the last 7 days, oldest→newest.
final weeklyPickupsProvider = StreamProvider<List<double>>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(6);

  final query = db.select(db.pickupsLog)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final byDay = {for (final r in rows) r.day: r.count};
    return List.generate(7, (i) {
      final day = _daysAgo(6 - i);
      return (byDay[day] ?? 0).toDouble();
    });
  });
});

/// Consecutive-day streak, computed from days that have *any* recorded
/// AppUsage row — i.e. the app was actually used/tracked that day.
/// Walks backward from today; breaks on the first missing day.
final currentStreakProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _daysAgo(60); // 60-day lookback is plenty for any realistic streak

  final query = db.select(db.appUsage)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final daysWithData = rows.map((r) => r.day).toSet();
    var streak = 0;
    var cursor = _startOfDay(DateTime.now());
    while (daysWithData.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  });
});

/// The Limit score badge tiers, per the design system — 0 to 1000 in
/// 10 bands. Kept alongside the calculation so a UI never has to
/// hardcode a tier name against a score by hand.
class ScoreTier {
  const ScoreTier(this.name, this.min, this.max);
  final String name;
  final int min;
  final int max;
}

const scoreTiers = [
  ScoreTier('Newcomer', 0, 99),
  ScoreTier('Aware', 100, 199),
  ScoreTier('Steady', 200, 299),
  ScoreTier('Disciplined', 300, 399),
  ScoreTier('Focused', 400, 499),
  ScoreTier('Resolute', 500, 599),
  ScoreTier('Mindful', 600, 699),
  ScoreTier('Unshaken', 700, 799),
  ScoreTier('Sovereign', 800, 899),
  ScoreTier('Limitless', 900, 1000),
];

ScoreTier tierFor(int score) =>
    scoreTiers.firstWhere((t) => score >= t.min && score <= t.max, orElse: () => scoreTiers.first);

class LimitScore {
  const LimitScore({required this.score, required this.tier, required this.toNextTier});
  final int score;
  final ScoreTier tier;
  final int toNextTier;
}

/// Real weighted calculation from the design doc's formula — screen-time
/// reduction 35%, focus consistency 30%, streak 20%, limits kept 15% —
/// computed live from today's actual data rather than a fixture. Each
/// component is normalized to 0–1 before weighting so the formula stays
/// meaningful regardless of how ambitious someone's budget is.
final limitScoreProvider = Provider<AsyncValue<LimitScore>>((ref) {
  final weeklyUsage = ref.watch(weeklyScreenTimeHoursProvider);
  final weeklyFocus = ref.watch(weeklyFocusSecondsProvider);
  final streak = ref.watch(currentStreakProvider);
  final budget = ref.watch(dailyBudgetProvider);

  // Combine four AsyncValues manually rather than pulling in a
  // multi-provider-combinator package for one screen's worth of use.
  if (weeklyUsage.isLoading || weeklyFocus.isLoading || streak.isLoading || budget.isLoading) {
    return const AsyncValue.loading();
  }
  final usage = weeklyUsage.valueOrNull;
  final focusSeconds = weeklyFocus.valueOrNull;
  final streakDays = streak.valueOrNull;
  final budgetMinutes = budget.valueOrNull;
  if (usage == null || focusSeconds == null || streakDays == null || budgetMinutes == null) {
    return const AsyncValue.loading();
  }

  final budgetHours = budgetMinutes / 60.0;
  final avgUsedHours = usage.isEmpty ? 0.0 : usage.reduce((a, b) => a + b) / usage.length;
  final screenTimeComponent = (1 - (avgUsedHours / (budgetHours <= 0 ? 1 : budgetHours))).clamp(0.0, 1.0);

  // 5 focused hours/week treated as "full marks" for consistency —
  // arbitrary but reasonable target; tune once real usage data exists.
  final focusConsistencyComponent = (focusSeconds / (5 * 3600)).clamp(0.0, 1.0);

  final streakComponent = (streakDays / 30).clamp(0.0, 1.0); // 30-day streak = full marks

  // Limits-kept component needs RestrictionGroups override/breach
  // tracking, which isn't built yet — held at a neutral 0.7 rather than
  // faking a precise number until that data source exists.
  const limitsKeptComponent = 0.7;

  final total = (screenTimeComponent * 0.35) +
      (focusConsistencyComponent * 0.30) +
      (streakComponent * 0.20) +
      (limitsKeptComponent * 0.15);

  final score = (total * 1000).round().clamp(0, 1000);
  final tier = tierFor(score);
  final toNext = tier.max >= 1000 ? 0 : (tier.max + 1 - score);

  return AsyncValue.data(LimitScore(score: score, tier: tier, toNextTier: toNext));
});
PATCH_EOF

mkdir -p "lib/data"
cat > "lib/data/permissions_providers.dart" << 'PATCH_EOF'
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/native/permissions_channel.dart';

/// Bumped to force every permission provider to re-check native state —
/// call `ref.invalidate` via this after returning from system Settings
/// (Android gives no callback for "user came back from Settings", so
/// polling on resume is the standard, correct pattern here).
final permissionsRefreshTickProvider = StateProvider<int>((ref) => 0);

final accessibilityEnabledProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isAccessibilityEnabled();
});

final deviceAdminActiveProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isDeviceAdminActive();
});

final notificationListenerEnabledProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isNotificationListenerEnabled();
});

final vpnPermissionGrantedProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.hasVpnPermission();
});

final postNotificationsGrantedProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isPostNotificationsGranted();
});

final biometricAvailableProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isBiometricAvailable();
});

/// One combined item type the onboarding screen renders from — keeps
/// the widget dumb (map over a list) instead of five near-identical
/// card widgets hand-wired to five different providers.
enum PermissionKind { accessibility, vpn, deviceAdmin, notificationListener, biometric }

class PermissionStatus {
  const PermissionStatus({required this.kind, required this.granted, required this.loading});
  final PermissionKind kind;
  final bool granted;
  final bool loading;
}

final allPermissionsProvider = Provider<List<PermissionStatus>>((ref) {
  final accessibility = ref.watch(accessibilityEnabledProvider);
  final vpn = ref.watch(vpnPermissionGrantedProvider);
  final deviceAdmin = ref.watch(deviceAdminActiveProvider);
  final notifications = ref.watch(notificationListenerEnabledProvider);
  final biometric = ref.watch(biometricAvailableProvider);

  PermissionStatus build(PermissionKind kind, AsyncValue<bool> value) => PermissionStatus(
        kind: kind,
        granted: value.valueOrNull ?? false,
        loading: value.isLoading,
      );

  return [
    build(PermissionKind.accessibility, accessibility),
    build(PermissionKind.vpn, vpn),
    build(PermissionKind.deviceAdmin, deviceAdmin),
    build(PermissionKind.notificationListener, notifications),
    build(PermissionKind.biometric, biometric),
  ];
});

/// True once every *required* permission (all but the optional
/// biometric) is granted. Drives the app-level gate in main.dart — once
/// this flips true, Home renders automatically, no manual navigation
/// needed.
final requiredPermissionsGrantedProvider = Provider<bool>((ref) {
  final all = ref.watch(allPermissionsProvider);
  return all
      .where((p) => p.kind != PermissionKind.biometric)
      .every((p) => p.granted);
});
PATCH_EOF

mkdir -p "lib/data"
cat > "lib/data/usage_tracker.dart" << 'PATCH_EOF'
import 'dart:async';
import 'package:drift/drift.dart';
import '../../core/native/usage_events_channel.dart';
import 'db/app_database.dart';

/// Bridges native foreground-app events into real Drift rows. Started
/// once at app launch (see main.dart) and lives for the app's process
/// lifetime.
///
/// Model: on every new foreground event, attribute the elapsed time
/// since the *previous* event to the *previous* package — i.e. "how
/// long was the last app actually in front of the user." The very
/// first event in a session has nothing to attribute yet, so it's
/// stored and only resolved once the next transition arrives.
///
/// Known simplification: if a session spans midnight, the elapsed time
/// is attributed entirely to the day of the earlier timestamp rather
/// than split across the boundary. Acceptable for a v1 — the error is
/// bounded by one app's single foreground duration, not compounding.
class UsageTracker {
  UsageTracker(this._db);

  final AppDatabase _db;
  StreamSubscription<ForegroundEvent>? _sub;

  String? _pendingPackage;
  int? _pendingTimestampMillis;

  void start() {
    _sub = UsageEventsChannel.stream.listen(_onEvent, onError: (_) {
      // Accessibility service not enabled yet, or channel not ready —
      // fail silently rather than crash the app; permission screens
      // surface the "not granted" state explicitly elsewhere.
    });
  }

  void dispose() => _sub?.cancel();

  Future<void> _onEvent(ForegroundEvent event) async {
    final now = event.timestampMillis;

    if (_pendingPackage != null && _pendingTimestampMillis != null) {
      final elapsedSeconds = ((now - _pendingTimestampMillis!) / 1000).round();
      if (elapsedSeconds > 0 && elapsedSeconds < 6 * 3600) {
        // Discard >6h gaps — almost certainly a phone-asleep period the
        // OS didn't cleanly signal, not real foreground time.
        await _addUsage(_pendingPackage!, _pendingTimestampMillis!, elapsedSeconds);
      }
      // A genuine app switch (not the same package re-firing) is what
      // "pickups" counts.
      if (_pendingPackage != event.packageName) {
        await _incrementPickup(now);
      }
    } else {
      await _incrementPickup(now);
    }

    _pendingPackage = event.packageName;
    _pendingTimestampMillis = now;
  }

  Future<void> _addUsage(String package, int atMillis, int seconds) async {
    final day = _truncateToDay(DateTime.fromMillisecondsSinceEpoch(atMillis));
    // Real upsert leaning on the (packageName, day) unique key from the
    // schema: insert a fresh row, or atomically add to the existing
    // one's foreground_seconds. One statement, no read-then-write race.
    await _db.customStatement(
      '''
      INSERT INTO app_usage (package_name, day, foreground_seconds)
      VALUES (?, ?, ?)
      ON CONFLICT(package_name, day)
      DO UPDATE SET foreground_seconds = foreground_seconds + excluded.foreground_seconds
      ''',
      [package, day.millisecondsSinceEpoch, seconds],
    );
  }

  Future<void> _incrementPickup(int atMillis) async {
    final day = _truncateToDay(DateTime.fromMillisecondsSinceEpoch(atMillis));
    final existing = await (_db.select(_db.pickupsLog)..where((t) => t.day.equals(day)))
        .getSingleOrNull();
    if (existing == null) {
      await _db.into(_db.pickupsLog).insert(PickupsLogCompanion.insert(day: day, count: const Value(1)));
    } else {
      await (_db.update(_db.pickupsLog)..where((t) => t.day.equals(day)))
          .write(PickupsLogCompanion(count: Value(existing.count + 1)));
    }
  }

  DateTime _truncateToDay(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
}
PATCH_EOF

mkdir -p "lib/features/home"
cat > "lib/features/home/home_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/providers.dart';
import '../../data/home_data_providers.dart';
import '../../shared/widgets/limit_ring.dart';
import '../../shared/widgets/trend_chart.dart';
import '../../shared/widgets/pressable_scale.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenTime = ref.watch(todayScreenTimeProvider);
    final budgetMinutes = ref.watch(dailyBudgetProvider);
    final score = ref.watch(limitScoreProvider);
    final streak = ref.watch(currentStreakProvider);
    final weeklyUsage = ref.watch(weeklyScreenTimeHoursProvider);
    final weeklyFocusSeconds = ref.watch(weeklyFocusSecondsProvider);
    final weeklyFocusHours = ref.watch(weeklyFocusHoursByDayProvider);
    final weeklyPickups = ref.watch(weeklyPickupsProvider);

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topCenter,
          radius: 1.15,
          colors: [Color(0x3A8B7FE8), Colors.transparent],
          stops: [0.0, 0.6],
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
          children: [
            _Header(streak: streak.valueOrNull ?? 0),
            const SizedBox(height: 18),

            _LimitScoreBanner(score: score),
            const SizedBox(height: 22),

            Center(
              child: _buildRing(screenTime, budgetMinutes),
            ),
            const SizedBox(height: 28),

            const _SectionLabel('THIS WEEK'),
            const SizedBox(height: 10),
            _WeeklyTrendCard(weeklyHours: weeklyUsage),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _MiniTrendCard(
                    label: 'Focus time',
                    valueText: _formatFocusTotal(weeklyFocusSeconds.valueOrNull),
                    values: weeklyFocusHours.valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MiniTrendCard(
                    label: 'Pickups / day',
                    valueText: _formatPickupsAvg(weeklyPickups.valueOrNull),
                    values: weeklyPickups.valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),

            const _SectionLabel('CONTROLS'),
            const SizedBox(height: 10),
            const _ControlsGrid(),
          ],
        ),
      ),
    );
  }

  Widget _buildRing(AsyncValue<Duration> screenTime, AsyncValue<int> budgetMinutes) {
    if (screenTime.isLoading || budgetMinutes.isLoading) {
      return const LimitRing(progress: 0, size: 130, trackColor: AppColors.stroke);
    }
    final used = screenTime.valueOrNull ?? Duration.zero;
    final budget = Duration(minutes: budgetMinutes.valueOrNull ?? 240);
    return _ScreenTimeRing(used: used, budget: budget);
  }

  String _formatFocusTotal(int? seconds) {
    if (seconds == null || seconds == 0) return '0m';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }

  String _formatPickupsAvg(List<double>? days) {
    if (days == null || days.isEmpty) return '—';
    final avg = days.reduce((a, b) => a + b) / days.length;
    return avg.round().toString();
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.streak});
  final int streak;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Today', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text(_formattedDate(), style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        if (streak > 0) _StreakBadge(days: streak),
      ],
    );
  }

  String _formattedDate() {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final now = DateTime.now();
    return '${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
  }
}

class _StreakBadge extends StatelessWidget {
  const _StreakBadge({required this.days});
  final int days;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_fire_department_rounded, size: 13, color: AppColors.accentSoft),
          const SizedBox(width: 5),
          Text('$days day streak',
              style: const TextStyle(fontSize: 11, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.labelSmall);
}

class _ScreenTimeRing extends StatelessWidget {
  const _ScreenTimeRing({required this.used, required this.budget});
  final Duration used;
  final Duration budget;

  @override
  Widget build(BuildContext context) {
    final remaining = budget - used;
    final safeBudget = budget.inSeconds <= 0 ? 1 : budget.inSeconds;
    final progress = 1 - (used.inSeconds / safeBudget).clamp(0.0, 1.0);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: progress),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: AppColors.accent.withOpacity(0.18), blurRadius: 40, spreadRadius: 4),
          ],
        ),
        child: LimitRing(
          progress: value,
          size: 130,
          strokeWidth: 9,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_formatDuration(remaining), style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text('LEFT TODAY', style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final clamped = d.isNegative ? Duration.zero : d;
    final h = clamped.inHours;
    final m = clamped.inMinutes % 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _LimitScoreBanner extends StatelessWidget {
  const _LimitScoreBanner({required this.score});
  final AsyncValue<LimitScore> score;

  @override
  Widget build(BuildContext context) {
    final data = score.valueOrNull;

    return PressableScale(
      onTap: () {}, // wire to Routes.score detail push
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.stroke),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [AppColors.accent.withOpacity(0.14), AppColors.surface],
            stops: const [0.0, 0.65],
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(colors: [AppColors.accent, AppColors.accentSoft, AppColors.accent]),
              ),
              child: Center(
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(color: AppColors.surface, shape: BoxShape.circle),
                  child: const Icon(Icons.shield_rounded, size: 18, color: AppColors.ink),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(data == null ? '—' : '${data.score}',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 6),
                      Text('Limit',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600, color: AppColors.inkDim)),
                    ],
                  ),
                  Text(
                    data == null
                        ? 'Calculating…'
                        : '${data.tier.name} tier · ${data.toNextTier} to next badge',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.accent, size: 18),
          ],
        ),
      ),
    );
  }
}

class _WeeklyTrendCard extends StatelessWidget {
  const _WeeklyTrendCard({required this.weeklyHours});
  final AsyncValue<List<double>> weeklyHours;

  @override
  Widget build(BuildContext context) {
    final values = weeklyHours.valueOrNull;
    final hasData = values != null && values.any((v) => v > 0);
    final avg = hasData ? values.reduce((a, b) => a + b) / values.length : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Avg. daily screen time',
              style: TextStyle(fontSize: 12, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            hasData ? _formatHours(avg) : 'No data yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          if (hasData)
            TrendAreaChart(values: values)
          else
            // First-run / no-Accessibility-permission state — an empty
            // chart card reads as broken, so say so explicitly instead.
            SizedBox(
              height: 84,
              child: Center(
                child: Text(
                  'Enable Accessibility access to start tracking',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, color: AppColors.inkFaint),
                ),
              ),
            ),
          const SizedBox(height: 4),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _DayLabel('M'), _DayLabel('T'), _DayLabel('W'), _DayLabel('T'),
              _DayLabel('F'), _DayLabel('S'), _DayLabel('S'),
            ],
          ),
        ],
      ),
    );
  }

  String _formatHours(double hours) {
    final h = hours.floor();
    final m = ((hours - h) * 60).round();
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 9, color: AppColors.inkFaint));
}

class _MiniTrendCard extends StatelessWidget {
  const _MiniTrendCard({
    required this.label,
    required this.valueText,
    required this.values,
  });

  final String label;
  final String valueText;
  final List<double> values;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Sparkline(values: values),
          const SizedBox(height: 6),
          Text(valueText,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _ControlsGrid extends StatelessWidget {
  const _ControlsGrid();

  static const _tiles = [
    ('Focus', Icons.track_changes_rounded, 'Start a session'),
    ('App Limits', Icons.grid_view_rounded, 'Manage groups'),
    ('App Blocking', Icons.block_rounded, 'Manage blocked apps'),
    ('Internet & Sites', Icons.public_rounded, 'VPN & filters'),
    ('Notifications', Icons.notifications_rounded, 'Manage delivery'),
    ('Bedtime', Icons.dark_mode_rounded, 'Manage schedule'),
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _tiles.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 9,
        crossAxisSpacing: 9,
        childAspectRatio: 1.5,
      ),
      itemBuilder: (context, i) {
        final (title, icon, subtitle) = _tiles[i];
        return _ControlTile(title: title, icon: icon, subtitle: subtitle);
      },
    );
  }
}

class _ControlTile extends StatelessWidget {
  const _ControlTile({required this.title, required this.icon, required this.subtitle});
  final String title;
  final IconData icon;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: () {},
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 15, color: AppColors.accentSoft),
            ),
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 12.5)),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10)),
          ],
        ),
      ),
    );
  }
}
PATCH_EOF

mkdir -p "lib/features/onboarding"
cat > "lib/features/onboarding/permissions_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../core/native/permissions_channel.dart';
import '../../data/permissions_providers.dart';

class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key, required this.onAllGranted});

  /// Called once every non-optional permission is granted, so the
  /// caller can advance the router — kept as a callback rather than
  /// this screen owning navigation, so it's reusable from both first
  /// launch and Settings → Permissions.
  final VoidCallback onAllGranted;

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android gives no callback for "user returned from Settings" — the
    // correct, standard pattern is to re-check every relevant permission
    // when the app resumes, since that's the only reliable signal.
    if (state == AppLifecycleState.resumed) {
      ref.read(permissionsRefreshTickProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(allPermissionsProvider);

    // Biometric is optional (see design) — required count excludes it.
    final required = permissions.where((p) => p.kind != PermissionKind.biometric);
    final grantedCount = required.where((p) => p.granted).length;
    final requiredTotal = required.length;
    final allRequiredGranted = grantedCount == requiredTotal;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            children: [
              const SizedBox(height: 6),
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(Icons.lock_rounded, color: AppColors.accentSoft, size: 22),
              ),
              const SizedBox(height: 12),
              Text(
                'Ulimit needs a few permissions',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              Text(
                'Everything stays on your device — nothing is ever uploaded. '
                'Each permission only powers the feature next to it.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView.separated(
                  itemCount: permissions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _PermissionCard(status: permissions[i]),
                ),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: requiredTotal == 0 ? 0 : grantedCount / requiredTotal,
                  minHeight: 5,
                  backgroundColor: AppColors.stroke,
                  valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                ),
              ),
              const SizedBox(height: 8),
              Text('$grantedCount of $requiredTotal granted',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: allRequiredGranted ? widget.onAllGranted : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.ink,
                    disabledBackgroundColor: AppColors.surface2,
                    padding: const EdgeInsets.all(15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: Text(
                    'Continue',
                    style: TextStyle(
                      color: allRequiredGranted ? AppColors.bg : AppColors.inkFaint,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionMeta {
  const _PermissionMeta(this.title, this.description, this.icon, this.iconColor, this.optional);
  final String title;
  final String description;
  final IconData icon;
  final Color iconColor;
  final bool optional;
}

const _meta = {
  PermissionKind.accessibility: _PermissionMeta(
    'Accessibility',
    'The core engine — detects app usage, enforces limits, and shows the block screen instantly.',
    Icons.visibility_rounded,
    AppColors.danger,
    false,
  ),
  PermissionKind.vpn: _PermissionMeta(
    'VPN & Network',
    'Creates a local, on-device filter for internet and website blocking.',
    Icons.public_rounded,
    AppColors.accentSoft,
    false,
  ),
  PermissionKind.deviceAdmin: _PermissionMeta(
    'Device Admin',
    "Stops Ulimit from being uninstalled or force-stopped to bypass a limit.",
    Icons.shield_rounded,
    AppColors.accentSoft,
    false,
  ),
  PermissionKind.notificationListener: _PermissionMeta(
    'Notification Access',
    'Lets Ulimit batch or mute notifications during focus sessions.',
    Icons.notifications_rounded,
    AppColors.accentSoft,
    false,
  ),
  PermissionKind.biometric: _PermissionMeta(
    'Biometrics',
    'Optional — protects your limits from being changed by others.',
    Icons.fingerprint_rounded,
    AppColors.accentSoft,
    true,
  ),
};

class _PermissionCard extends ConsumerWidget {
  const _PermissionCard({required this.status});
  final PermissionStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = _meta[status.kind]!;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: meta.iconColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(meta.icon, size: 15, color: meta.iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(meta.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13)),
                const SizedBox(height: 2),
                Text(meta.description, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _ActionButton(status: status, optional: meta.optional),
        ],
      ),
    );
  }
}

class _ActionButton extends ConsumerWidget {
  const _ActionButton({required this.status, required this.optional});
  final PermissionStatus status;
  final bool optional;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (status.granted) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(AppRadius.pill)),
        child: const Text('✓ Done', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
      );
    }

    return GestureDetector(
      onTap: status.loading ? null : () => _handleTap(ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: optional ? AppColors.surface2 : AppColors.accent,
          border: optional ? Border.all(color: AppColors.stroke) : null,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          optional ? 'Skip' : 'Allow',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: optional ? AppColors.inkDim : Colors.white,
          ),
        ),
      ),
    );
  }

  Future<void> _handleTap(WidgetRef ref) async {
    // Accessibility and Notification Listener can only be toggled from
    // system Settings — Android has no in-app grant dialog for either.
    // The rest support a direct system dialog.
    switch (status.kind) {
      case PermissionKind.accessibility:
        await NativePermissions.openAccessibilitySettings();
      case PermissionKind.notificationListener:
        await NativePermissions.openNotificationListenerSettings();
      case PermissionKind.vpn:
        await NativePermissions.requestVpnPermission();
      case PermissionKind.deviceAdmin:
        await NativePermissions.requestDeviceAdmin();
      case PermissionKind.biometric:
        // "Skip" for the optional card — nothing to request, just move
        // on; availability is a device capability, not a togglable
        // permission, so there's nothing else to do here.
        return;
    }
    // VPN/Device Admin dialogs resolve synchronously enough that an
    // immediate re-check is worthwhile; Accessibility/Notification
    // Listener rely on the lifecycle-resume re-check instead since the
    // user is leaving the app to a Settings screen.
    ref.read(permissionsRefreshTickProvider.notifier).state++;
  }
}
PATCH_EOF

mkdir -p "lib"
cat > "lib/main.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'data/permissions_providers.dart';
import 'data/providers.dart';
import 'data/usage_tracker.dart';
import 'features/onboarding/permissions_screen.dart';

void main() {
  runApp(const ProviderScope(child: UlimitApp()));
}

class UlimitApp extends ConsumerStatefulWidget {
  const UlimitApp({super.key});

  @override
  ConsumerState<UlimitApp> createState() => _UlimitAppState();
}

class _UlimitAppState extends ConsumerState<UlimitApp> {
  UsageTracker? _tracker;

  @override
  Widget build(BuildContext context) {
    _tracker ??= UsageTracker(ref.read(databaseProvider))..start();

    final permissionsGranted = ref.watch(requiredPermissionsGrantedProvider);

    // The gate: until every required permission is granted, the app
    // shows nothing but the permissions screen — there's no route to
    // Home, Focus, or any control screen with the enforcement engine
    // half-wired, which would just be a UI that lies about what it's
    // doing. Two distinct MaterialApp branches (rather than swapping
    // `home` on one instance) keeps go_router's own Navigator fully
    // out of the picture until it's actually needed.
    if (!permissionsGranted) {
      return MaterialApp(
        title: 'Ulimit',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        home: PermissionsScreen(
          onAllGranted: () {}, // no-op — the provider watch above
          // handles the transition the instant permissionsGranted flips
          // true; see requiredPermissionsGrantedProvider's doc comment.
        ),
      );
    }

    return MaterialApp.router(
      title: 'Ulimit',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: appRouter,
    );
  }

  @override
  void dispose() {
    _tracker?.dispose();
    super.dispose();
  }
}
PATCH_EOF

git add -A
git -c user.email="dev@ulimit.app" -c user.name="Ulimit Dev" commit -m "Add real permission handling (Accessibility, Device Admin, VPN, Notification Listener, Biometric) and wire Home screen to live Drift-backed data instead of hardcoded values"
git push

echo "Pushed. Removing this script."
rm -- "$0"
