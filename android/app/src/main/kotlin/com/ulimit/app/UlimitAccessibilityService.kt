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
            showOverlay(packageName, reason.reason, reason.untilMillis, now)
        } else if (overlayPackageName != null && overlayPackageName != packageName) {
            // The user navigated to a non-blocked app — dismiss our
            // overlay. If the overlay is for THIS package the block just
            // expired here, so we leave it to the overlay's own 5s
            // closing pill (a stray same-app event must not cut the pill
            // short and unblock the app before the grace period ends).
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
            // Window token problems — retry on the next event.
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
