package com.ulimit.app

import android.accessibilityservice.AccessibilityService
import android.util.Log
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The core enforcement + tracking layer. Every window-state change
 * (the OS's signal for "a different app is now in front") flows through
 * here and does three things:
 *
 *  1. Attributes elapsed foreground time to the previous package and
 *     accumulates it in the native usage store — this is what lets a
 *     daily limit fire even when Ulimit itself is closed.
 *  2. Evaluates the policy snapshot for the now-foreground package and,
 *     if blocked, shows a full-screen TYPE_ACCESSIBILITY_OVERLAY so the
 *     blocked app never becomes usable.
 *  3. Forwards the transition to Dart (UsageEventBridge) where the
 *     authoritative usage history is persisted to SQLite.
 */
class UlimitAccessibilityService : AccessibilityService() {

    private var lastPackageName: String? = null
    private var lastEventTimestamp: Long = 0

    private var overlayView: View? = null
    private var overlayPackageName: String? = null

    // Services expose WindowManager through getSystemService, not a
    // `windowManager` property (that's an Activity API).
    private val windowManagerService: WindowManager by lazy {
        getSystemService(WINDOW_SERVICE) as WindowManager
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return

        val packageName = event.packageName?.toString() ?: return
        val now = System.currentTimeMillis()

        // The system UI and this app itself aren't "the user picked a
        // different app" transitions worth ENFORCING, but they ARE real
        // usage boundaries: opening Ulimit while scrolling Instagram
        // means Instagram stops being foreground at that instant. Emit
        // the switch BEFORE the early return so Dart closes the pending
        // window and time inside Ulimit is never attributed to the app
        // it left behind. Note: the overlay is still hidden here, and
        // lastPackageName is intentionally NOT updated for systemui -
        // returning to the same app must re-run enforcement because the
        // policy may have changed in between.
        if (packageName == this.packageName) {
            UsageEventBridge.emit(packageName, now)
            hideOverlay()
            return
        }
        if (packageName.startsWith("com.android.systemui")) {
            hideOverlay()
            return
        }

        // 1. ENFORCEMENT FIRST — on every window-state event, even for
        // the same package as the previous event. The dedupe below only
        // applies to usage tracking; skipping enforcement here created a
        // window where a blocked app was fully usable (e.g.
        // blocked app → Recents (system UI) → blocked app again, or
        // blocked app → Ulimit → blocked app again).
        val reason = PolicySnapshot.shouldBlock(this, packageName, now)
        if (PolicySnapshot.isDebugBuild(this)) {
            Log.d(
                "UlimitBlock",
                "foreground=$packageName blocked=${reason != null} reason=$reason"
            )
        }
        if (reason != null) {
            showOverlay(packageName, reason)
        } else if (overlayPackageName == packageName) {
            // Only clear our own overlay; another package's event must
            // not hide an overlay that is still valid for it.
            hideOverlay()
        }

        // 2. Usage tracking dedupe — after enforcement.
        if (packageName == lastPackageName) return

        val previous = lastPackageName
        if (previous != null && lastEventTimestamp > 0) {
            val elapsedSeconds = ((now - lastEventTimestamp) / 1000).toInt()
            // Discard huge gaps — almost certainly a phone-asleep period
            // the OS didn't cleanly signal, not real foreground time.
            if (elapsedSeconds in 1..(6 * 3600)) {
                PolicySnapshot.addForegroundSeconds(this, previous, elapsedSeconds)
            }
        }
        lastPackageName = packageName
        lastEventTimestamp = now

        // 3. Forward the transition to Dart (which owns the authoritative
        // SQLite usage history and pickup counting). Native emits the
        // *new* package; Dart attributes elapsed time itself.
        UsageEventBridge.emit(packageName, now)
    }

    override fun onInterrupt() {
        // Required override; nothing to clean up — the overlay is torn
        // down in onServiceConnected/onUnbind paths instead.
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        lastPackageName = null
        lastEventTimestamp = 0
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        hideOverlay()
        return super.onUnbind(intent)
    }

    // ------------------------------------------------------------------
    // Blocking overlay
    // ------------------------------------------------------------------

    private fun showOverlay(packageName: String, reason: String) {
        if (overlayView != null && overlayPackageName == packageName) return
        hideOverlay()

        val appName = try {
            val pm = packageManager
            val info = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(info)?.toString() ?: packageName
        } catch (_: Exception) {
            packageName
        }

        val density = resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#0A0A0B"))
            setPadding(dp(32), dp(32), dp(32), dp(32))
        }

        val appNameView = TextView(this).apply {
            text = appName
            setTextColor(Color.parseColor("#F5F5F4"))
            textSize = 22f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            gravity = Gravity.CENTER
        }

        val reasonView = TextView(this).apply {
            text = reason
            setTextColor(Color.parseColor("#A3A3A6"))
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, 0)
        }

        val byline = TextView(this).apply {
            text = "Blocked by Ulimit"
            setTextColor(Color.parseColor("#6B6B6F"))
            textSize = 12f
            gravity = Gravity.CENTER
            setPadding(0, dp(4), 0, 0)
        }

        val backButton = Button(this).apply {
            text = "Back"
            setTextColor(Color.parseColor("#0A0A0B"))
            setPadding(dp(28), dp(10), dp(28), dp(10))
            setOnClickListener {
                hideOverlay()
                performGlobalAction(GLOBAL_ACTION_HOME)
            }
        }

        root.addView(appNameView)
        root.addView(reasonView)
        root.addView(byline)
        root.addView(
            backButton,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(28)
                gravity = Gravity.CENTER_HORIZONTAL
            }
        )

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        )

        try {
            windowManagerService.addView(root, params)
            overlayView = root
            overlayPackageName = packageName
        } catch (_: Exception) {
            // Window token problems (e.g. mid-teardown) — enforcement
            // retries on the very next accessibility event.
        }
    }

    private fun hideOverlay() {
        val view = overlayView ?: return
        try {
            windowManagerService.removeView(view)
        } catch (_: Exception) {
        }
        overlayView = null
        overlayPackageName = null
    }
}
