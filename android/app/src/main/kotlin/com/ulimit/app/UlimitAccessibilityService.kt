package com.ulimit.app

import android.accessibilityservice.AccessibilityService
import android.app.Service.USAGE_STATS_SERVICE
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.util.Log
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

import android.widget.LinearLayout
import android.widget.TextView

/**
 * The core enforcement + tracking layer. The block decision is evaluated
 * for the real foreground app AND continuously re-checked on a timer:
 *
 *  1. Foreground resolution is driven by the OS UsageStats
 *     ACTIVITY_RESUMED stream (so a blocked app is caught even when it
 *     exposes no accessibility window), falling back to the accessibility
 *     active window; a periodic loop keeps it fresh without waiting for a
 *     new window-state event.
 *  2. Evaluates the policy snapshot for that app and, if blocked, shows a
 *     full-screen touch-blocking overlay so the blocked app never becomes
 *     usable. The overlay is cleared only when the block expires or a
 *     genuinely different, non-blocked app comes to front.
 *  3. Attributes elapsed foreground time and forwards transitions to Dart
 *     (UsageEventBridge) where the authoritative usage history is
 *     persisted to SQLite.
 */
class UlimitAccessibilityService : AccessibilityService() {

    private var lastPackageName: String? = null
    private var lastEventTimestamp: Long = 0

    private var overlayView: View? = null
    private var overlayPackageName: String? = null

    // Continuous foreground enforcement. The block decision here is
    // re-evaluated on a timer, not only on window-state events, so a
    // block that ENGAGES while the target app is already in the
    // foreground (a daily/group limit crossed mid-session, a focus or
    // bedtime window opening, a manual block, or a snapshot that landed
    // a moment earlier) is applied immediately instead of being silently
    // skipped until the user switches apps.
    private val enforceHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val enforceIntervalMs = 1000L
    private var enforceLoopRunning = false
    private val enforceForeground = object : Runnable {
        override fun run() {
            if (!enforceLoopRunning) return
            enforceCurrentForeground()
            enforceHandler.postDelayed(this, enforceIntervalMs)
        }
    }

    // UsageStats-backed foreground detection (the approach the Mindful
    // reference uses): the OS ACTIVITY_RESUMED stream identifies the real
    // foreground app even when that app exposes no accessibility window
    // content, so a blocked app's launch is caught regardless. Both are
    // only touched on the main thread (Handler loop + events).
    private var fgLastResumed = ""
    private var lastUsageQueryAt = 0L

    // Adult-content screen scanning state: while the adult filter is
    // enabled we read the visible text of the current browser app and,
    // if it contains a domain from the blocked set, back out
    // automatically. Kept as fields so the scan debounce survives
    // across events (done once per ~2s per package, never on the UI
    // thread — accessibility content reads ARE the UI thread here, so
    // the work must stay bounded).
    private var lastContentScanPackage: String? = null
    private var lastContentScanAt: Long = 0
    private var lastContentScanDomain: String? = null

    // Services expose WindowManager through getSystemService, not a
    // `windowManager` property (that's an Activity API).
    private val windowManagerService: WindowManager by lazy {
        getSystemService(WINDOW_SERVICE) as WindowManager
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) {
            // Adult-content screen scan: the content change is the
            // signal that a browser page rendered new text (URL bar /
            // page content). Debounce per package, and only when the
            // adult filter is on.
            scanBrowserContent(event.packageName?.toString())
            return
        }

        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return

        val packageName = event.packageName?.toString() ?: return
        val now = System.currentTimeMillis()

        // Reaching Ulimit itself is only possible after the overlay was
        // already released (the Home escape hides it first), and the
        // accessibility overlay belongs to this app's package — so a
        // window-state event for our OWN window or for transient system
        // UI (notification shade / recents) must NOT tear down the
        // blocker. Doing so is exactly the open bypass: the overlay
        // disappears and the blocked app becomes usable again.
        if (packageName == this.packageName) {
            // Only close the usage window; never hide the block overlay.
            UsageEventBridge.emit(packageName, now)
            return
        }
        if (packageName.startsWith("com.android.systemui")) {
            // Not a usage boundary either; leave the overlay in place.
            return
        }

        // 1. ENFORCEMENT — apply the block to whatever real app surfaced.
        // The overlay window's own events and system UI were skipped
        // above, so neither can hide the blocker; the enforcement loop
        // re-asserts it every second as a safety net.
        enforceForPackage(packageName, now)

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
        stopEnforcementLoop()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        lastPackageName = null
        lastEventTimestamp = 0
        fgLastResumed = ""
        lastUsageQueryAt = 0L
        startEnforcementLoop()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        stopEnforcementLoop()
        hideOverlay()
        return super.onUnbind(intent)
    }

    // ------------------------------------------------------------------
    // Continuous foreground enforcement
    // ------------------------------------------------------------------

    private fun startEnforcementLoop() {
        if (enforceLoopRunning) return
        enforceLoopRunning = true
        enforceHandler.removeCallbacks(enforceForeground)
        enforceHandler.post(enforceForeground)
    }

    private fun stopEnforcementLoop() {
        enforceLoopRunning = false
        enforceHandler.removeCallbacks(enforceForeground)
    }

    /** Re-evaluates the policy for whatever is genuinely in front right
     *  now and shows/hides the blocking overlay accordingly. The
     *  foreground app is resolved from OS UsageStats (ACTIVITY_RESUMED),
     *  which works even when the app exposes no accessibility window, and
     *  falls back to [rootInActiveWindow] when usage access isn't granted. */
    private fun enforceCurrentForeground() {
        val now = System.currentTimeMillis()
        val pkg = currentForegroundFromUsageStats()
            ?: rootInActiveWindow?.packageName?.toString()
            ?: return
        enforceForPackage(pkg, now)
    }

    /** Returns the package of the most recently RESUMED app that has not
     *  been STOPPED, from the OS usage-event stream. Empty (→ fallback to
     *  the accessibility window) when usage access is missing or nothing
     *  is active. Runs on the main thread every loop tick. */
    private fun currentForegroundFromUsageStats(): String? {
        return try {
            val usm = getSystemService(USAGE_STATS_SERVICE) as? UsageStatsManager ?: return null
            val now = System.currentTimeMillis()
            val start = if (lastUsageQueryAt == 0L) now - 3000 else lastUsageQueryAt
            lastUsageQueryAt = now
            val events = usm.queryEvents(start, now)
            val event = UsageEvents.Event()
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                val pkg = event.packageName?.toString() ?: continue
                when (event.eventType) {
                    UsageEvents.Event.ACTIVITY_RESUMED -> fgLastResumed = pkg
                    UsageEvents.Event.ACTIVITY_STOPPED -> if (pkg == fgLastResumed) fgLastResumed = ""
                }
            }
            fgLastResumed.takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
    }

    /** Single enforcement decision shared by the event handler and the
     *  loop. Skips this app and system UI (neither may hide the blocker),
     *  shows the overlay for a blocked foreground, and only clears it when
     *  a genuinely different, non-blocked app is in front (the Home /
     *  another-app escape). */
    private fun enforceForPackage(pkg: String, now: Long) {
        if (pkg == this.packageName) return
        if (pkg.startsWith("com.android.systemui")) return
        val reason = PolicySnapshot.shouldBlock(this, pkg, now)
        if (PolicySnapshot.isDebugBuild(this)) {
            Log.d("UlimitBlock", "foreground=$pkg blocked=${reason != null} reason=$reason")
        }
        if (reason != null) {
            showOverlay(pkg, reason.reason, reason.untilMillis, now)
        } else if (overlayPackageName != null && overlayPackageName != pkg) {
            hideOverlay()
        }
    }

    // ------------------------------------------------------------------
    // Blocking overlay
    // ------------------------------------------------------------------

    private fun showOverlay(packageName: String, reason: String, untilMillis: Long, nowMillis: Long) {
        if (overlayView != null && overlayPackageName == packageName) return
        hideOverlay()

        val appName = try {
            val pm = packageManager
            val info = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(info)?.toString() ?: packageName
        } catch (_: Exception) {
            packageName
        }

        // App icon rendered inside the overlay (a Drawable in a square
        // white tile), because the Android app switcher/launcher icon
        // may not be reachable from this service otherwise.
        val appIcon = try {
            val pm = packageManager
            pm.getApplicationIcon(packageName)
        } catch (_: Exception) {
            null
        }

        val density = resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()

        // --- Root: full-screen, touch-blocking, dark backdrop -----------
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#EE0A0A0B"))
            setPadding(dp(32), dp(32), dp(32), dp(32))
        }

        // --- Icon tile: white rounded square with the app icon ----------
        val iconTile = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(0), dp(40), dp(0), dp(8))
        }
        val iconSize = dp(96)
        val iconHolder = android.widget.FrameLayout(this).apply {
            layoutParams = android.view.ViewGroup.LayoutParams(iconSize, iconSize)
            setBackgroundColor(Color.parseColor("#FFFFFFFF"))
            // rounded corners via a rounded drawable resource
        }
        iconHolder.background = android.graphics.drawable.GradientDrawable().apply {
            cornerRadius = dp(20).toFloat()
            color = android.content.res.ColorStateList.valueOf(
                Color.parseColor("#FFFFFFFF"))
        }
        appIcon?.let {
            val iconView = android.widget.ImageView(this).apply {
                setImageDrawable(it)
                layoutParams = android.view.ViewGroup.LayoutParams(dp(64), dp(64))
            }
            iconHolder.addView(iconView)
        }
        iconTile.addView(iconHolder)

        // --- App name ----------------------------------------------------
        val appNameView = TextView(this).apply {
            text = appName
            setTextColor(Color.parseColor("#F5F5F4"))
            textSize = 24f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(0, dp(20), 0, 0)
        }

        // --- Reason --------------------------------------------------------
        val reasonView = TextView(this).apply {
            text = reason
            setTextColor(Color.parseColor("#A3A3A6"))
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, dp(12), 0, 0)
        }

        // --- Remaining time + horizontal progress bar -----------------------
        val remainingView = TextView(this).apply {
            setTextColor(Color.parseColor("#F5F5F4"))
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(0, dp(24), 0, dp(10))
        }

        val progressBar = android.widget.ProgressBar(
            this, null, android.R.attr.progressBarStyleHorizontal
        ).apply {
            layoutParams = LinearLayout.LayoutParams(dp(240), dp(8))
            max = 100
            progress = 100
            progressTintList = android.content.res.ColorStateList.valueOf(
                Color.parseColor("#F0F0F0"))
            progressBackgroundTintList = android.content.res.ColorStateList.valueOf(
                Color.parseColor("#3A3A3E"))
        }

        // --- Byline ------------------------------------------------------
        val byline = TextView(this).apply {
            text = "Blocked by Ulimit"
            setTextColor(Color.parseColor("#6B6B6F"))
            textSize = 12f
            gravity = Gravity.CENTER
            setPadding(0, dp(16), 0, 0)
        }

        root.addView(iconTile)
        root.addView(appNameView)
        root.addView(reasonView)
        root.addView(remainingView)
        root.addView(progressBar)
        root.addView(byline)

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            // NOT_FOCUSABLE keeps keys/back away from the overlay;
            // touches still hit it (the blocked app can't be operated).
            // LAYOUT_IN_SCREEN/NO_LIMITS make it sit above the status
            // bar, system UI overlays and the app's own windows.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )

        try {
            windowManagerService.addView(root, params)
            overlayView = root
            overlayPackageName = packageName
        } catch (_: Exception) {
            // Window token problems — the continuous enforcement loop
            // retries on its next tick, so the block is never lost.
            return
        }

        // --- Countdown driven by the REAL restriction time ----------------
        // The progress bar is the remaining time of the period the user
        // set (NOT a fixed 5s countdown). The overlay stays up and
        // touch-blocks the app for the WHOLE restriction: the user cannot
        // use it until the time is up or the block is lifted. Only when
        // the restriction time reaches zero do we show a 5s "closing"
        // pill and then dismiss the overlay, so the app becomes usable
        // again. A permanent block (untilMillis == 0) never expires, so
        // the overlay just stays up until the user lifts the restriction.
        val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
        val indefinite = untilMillis <= 0L
        val totalAtShow = if (indefinite) 0L else (untilMillis - nowMillis).coerceAtLeast(0L)
        val closePillMillis = 5000L
        var closePillAt = -1L

        val countdown = object : Runnable {
            override fun run() {
                if (!isShownFor(packageName)) return
                val now = System.currentTimeMillis()

                if (indefinite) {
                    // Permanent: full bar, no countdown — stays up until
                    // the user lifts the restriction.
                    progressBar.progress = 100
                    remainingView.text = "Until manually removed"
                    return
                }

                val remaining = untilMillis - now
                if (remaining > 0) {
                    closePillAt = -1L
                    remainingView.text = formatRemainingTime(remaining)
                    progressBar.progress =
                        ((remaining * 100) / totalAtShow).toInt().coerceIn(0, 100)
                    mainHandler.postDelayed(this, 200)
                } else {
                    // Restriction time is up → 5s closing pill, then
                    // dismiss the overlay (the app is no longer blocked).
                    if (closePillAt < 0) closePillAt = now
                    val pillRemaining = closePillMillis - (now - closePillAt)
                    if (pillRemaining <= 0) {
                        hideOverlay()
                        return
                    }
                    val secs = (pillRemaining + 999) / 1000
                    byline.text = "Blocked by Ulimit · closing in ${secs}s"
                    progressBar.progress =
                        ((pillRemaining * 100) / closePillMillis).toInt().coerceIn(0, 100)
                    mainHandler.postDelayed(this, 200)
                }
            }
        }
        mainHandler.postDelayed(countdown, 100)
    }

    /** "2h 5m" / "34m 12s" / "9s" — the overlay's remaining-time text. */
    private fun formatRemainingTime(millis: Long): String {
        val totalSec = (millis / 1000).coerceAtLeast(0L)
        val h = totalSec / 3600
        val m = (totalSec % 3600) / 60
        val s = totalSec % 60
        return when {
            h > 0 -> "${h}h ${m}m"
            m > 0 -> "${m}m ${s}s"
            else -> "${s}s"
        }
    }

    /** True while [packageName] is still the overlay's target. */
    private fun isShownFor(packageName: String): Boolean =
        overlayView != null && overlayPackageName == packageName

    private fun hideOverlay() {
        val view = overlayView ?: return
        try {
            windowManagerService.removeView(view)
        } catch (_: Exception) {
        }
        overlayView = null
        overlayPackageName = null
    }

    // ------------------------------------------------------------------
    // Adult-content screen scanning (belt & braces for the DNS filter):
    // while the adult block-list is enabled, the visible text of the
    // foreground browser (URL bar + page) is scanned and — if a domain
    // from the blocked set is present — the browser is backed out
    // automatically with a one-time notice. This catches what DNS
    // filtering structurally cannot: DoH-resolved content, iframes from
    // third-party domains, and any domain matching missed by the DNS
    // layer. Bounded by design: at most one scan per package per ~2.5s,
    // a node/text budget, and cheap substring matching.
    // ------------------------------------------------------------------

    private val FQDN_REGEX = Regex("[a-z0-9-]+(\\.[a-z0-9-]+)+")

    private fun scanBrowserContent(packageName: String?) {
        if (packageName == null) return

        // Only when the adult filter is on and the foreground package is
        // a known browser — never scan other apps' text.
        val snapshot = PolicySnapshot.read(this) ?: return
        if (!snapshot.adultFilterEnabled) return
        if (packageName !in snapshot.browserPackages) return

        // Debounce: TYPE_WINDOW_CONTENT_CHANGED fires continuously as a
        // page paints. One scan per package per window.
        val now = System.currentTimeMillis()
        if (packageName == lastContentScanPackage &&
            now - lastContentScanAt < 2500
        ) {
            return
        }
        lastContentScanPackage = packageName
        lastContentScanAt = now

        val domains = loadScanDomains()
        if (domains.isEmpty()) return

        val text = collectVisibleText()
        if (text.isEmpty()) return

        for (match in FQDN_REGEX.findAll(text)) {
            val candidate = match.value.lowercase().trimEnd('.')
            if (candidate in domains) {
                // Blocked domain present in the visible browser content.
                // Back out and lock the package until it changes screens.
                onBlockedDomainInBrowser(packageName, candidate)
                return
            }
        }
    }

    /** Reads the blocked-domain set from the same file the DNS filter
     * uses (blocked_domains.txt) so the two layers never disagree. */
    private fun loadScanDomains(): Set<String> {
        return try {
            val file = java.io.File(filesDir, "blocked_domains.txt")
            if (!file.exists()) emptySet()
            else file.readLines()
                .asSequence()
                .map { it.trim().lowercase() }
                .filter { it.isNotEmpty() }
                .toSet()
        } catch (_: Exception) {
            emptySet()
        }
    }

    /** Traverses the active window's node tree and gathers visible text.
     * Bounded: stops after a node/char budget so a huge DOM or a deep
     * WebView can never stall the UI thread. */
    private fun collectVisibleText(): String {
        return try {
            val root = rootInActiveWindow ?: return ""
            val sb = StringBuilder()
            var nodes = 0
            fun walk(node: android.view.accessibility.AccessibilityNodeInfo?) {
                if (node == null || nodes > 600 || sb.length > 22000) return
                nodes++
                try {
                    val text = node.text?.toString()
                    if (!text.isNullOrBlank()) {
                        sb.append(text).append('.')
                    }
                    val desc = node.contentDescription?.toString()
                    if (!desc.isNullOrBlank()) {
                        sb.append(desc).append('.')
                    }
                    for (i in 0 until node.childCount) {
                        walk(node.getChild(i) ?: continue)
                    }
                } catch (_: Exception) {
                    // Node detached mid-walk — stop this subtree.
                } finally {
                    try {
                        node.recycle()
                    } catch (_: Exception) {
                    }
                }
            }
            walk(root)
            sb.toString()
        } catch (_: Exception) {
            ""
        }
    }

    private fun onBlockedDomainInBrowser(packageName: String, domain: String) {
        // One visible notice, then an automatic back. The back also
        // covers the case where the user manually entered a blocked
        // URL in the address bar (the typed URL shows up in the text).
        showSmallNotice(
            packageName = packageName,
            message = "Adult content blocked: $domain",
        )
        performGlobalAction(GLOBAL_ACTION_BACK)
    }

    /** A small top-of-screen badge (non-blocking — the browser still
     * shows behind it while the back happens). Auto-hides in 4s. */
    private fun showSmallNotice(packageName: String, message: String) {
        try {
            hideOverlay()
            val density = resources.displayMetrics.density
            fun dp(v: Int): Int = (v * density).toInt()

            val view = TextView(this).apply {
                text = "Blocked by Ulimit · $message"
                setTextColor(Color.parseColor("#F5F5F4"))
                setBackgroundColor(Color.parseColor("#CC0A0A0B"))
                textSize = 12f
                gravity = Gravity.CENTER
                setPadding(dp(20), dp(8), dp(20), dp(8))
            }

            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                dp(34),
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP
                y = dp(40)
            }

            windowManagerService.addView(view, params)
            overlayView = view
            overlayPackageName = packageName
            view.postDelayed({ hideOverlay() }, 4000)
        } catch (_: Exception) {
        }
    }
}
