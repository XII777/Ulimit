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
