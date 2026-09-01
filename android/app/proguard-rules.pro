# Ulimit ProGuard/R8 rules — release builds shrink + minimize.
#
# The core set below is the standard Flutter R8 template; the FFI keeps
# are required because sqlite3 (via drift) binds native structs with
# package:ffi, which R8 must not strip.

# --- Flutter engine + plugins -----------------------------------------
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.embedding.**  { *; }
-keep class io.flutter.**  { *; }
-dontwarn io.flutter.embedding.**

# --- Platform channels / activity / engine ------------------------------
-keep class io.flutter.plugin.common.MethodChannel { *; }
-keep class io.flutter.plugin.common.EventChannel { *; }
-keep class io.flutter.embedding.android.FlutterActivity { *; }
-keep class io.flutter.embedding.engine.FlutterEngine { *; }
-keep class io.flutter.embedding.engine.loader.FlutterLoader { *; }

# JNI native methods are invoked by name from native code.
-keepclasseswithmembers,includedescriptorclasses class * {
    native <methods>;
}

# --- package:ffi / sqlite3 native bindings ------------------------------
# R8 must not rename or strip FFI types: the generated Dart code looks
# them up by address/layout at runtime.
-keep class ffi.** { *; }
-keepclassmembers class * extends ffi.Struct { <fields>; }
-keepclassmembers class * extends ffi.Opaque { *; }
-keepclassmembers class * extends ffi.Allocator { *; }
-keep class sqlite3.** { *; }
-dontwarn ffi.**

# --- AndroidX ------------------------------------------------------------
-keep class androidx.biometric.** { *; }
-dontwarn androidx.biometric.**
-keep class androidx.core.** { *; }

# --- Kotlin -----------------------------------------------------------------
-keep class kotlin.Metadata { *; }

# --- Android framework classes referenced by name in the manifest ------------
# (receivers/services/activities declared in AndroidManifest.xml)
-keepclassmembers class * extends android.app.Service { *; }
-keepclassmembers class * extends android.app.Activity { *; }
-keepclassmembers class * extends android.content.BroadcastReceiver { *; }
-keepclassmembers class * extends android.accessibilityservice.AccessibilityService { *; }
-keepclassmembers class * extends android.net.VpnService { *; }
-keepclassmembers class * extends android.app.admin.DeviceAdminReceiver { *; }

# --- Debug logging stripped by R8 ---------------------------------------------
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}
