package com.ulimit.app

import android.accessibilityservice.AccessibilityService
import android.util.Log
import android.view.accessibility.AccessibilityEvent

/**
 * The core enforcement + tracking layer, structured after Mindful's
 * blocking system:
 *
 *  - [LaunchTrackingManager] owns launch detection — the OS
 *    ACTIVITY_RESUMED/PAUSED stream (executor poll every 750ms) plus the
 *    accessibility fast path — and fires [handleNewAppLaunch] once per
 *    app change.
 *  - [BlockRestrictionManager] evaluates a package against the native
 *    policy snapshot (Mindful's RestrictionManager role).
 *  - [BlockOverlayManager] owns the full-screen alert overlay window
 *    (Mindful's OverlayManager role).
 *  - This service wires the three together, keeps the adult-content
 *    window-text scanning (Mindful's accessibility content blocking),
 *    and attributes foreground time to Dart for the usage history.
 */
class UlimitAccessibilityService : AccessibilityService() {

    private var lastPackageName: String? = null
    private var lastEventTimestamp: Long = 0

    // Mindful-style architecture: launch tracking, restriction evaluation
    // and the block overlay are separate managers; this service hosts
    // them, publishes launches from accessibility events, and owns the
    // adult-content scanning (the same roles Mindful's tracker service +
    // accessibility service take together).
    private lateinit var launchTrackingManager: LaunchTrackingManager
    private lateinit var restrictionManager: BlockRestrictionManager
    private lateinit var overlayManager: BlockOverlayManager
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

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

    // Overlay windows are owned by BlockOverlayManager (Mindful's
    // OverlayManager role).

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

        if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) {
            // Window order/layout changed without a full state transition
            // (multi-window, split-screen, PiP-adjacent resizes, some OEM
            // launcher wrappers) — re-check the foreground NOW instead of
            // waiting up to the poll's next tick, so a just-fronted
            // blocked app is caught immediately.
            rootInActiveWindow?.packageName?.toString()?.let {
                launchTrackingManager.handleAccessibilityLaunch(it)
            }
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

        // 1. ENFORCEMENT — feed the launch to the tracking manager (same
        //    role as Mindful's TrackingManager broadcast, but a direct
        //    callback). The overlay window's own events and system UI
        //    were skipped above.
        launchTrackingManager.handleAccessibilityLaunch(packageName)

        // 2. Usage tracking dedupe — after enforcement.
        if (packageName == lastPackageName) return

        val previous = lastPackageName
        if (previous != null && lastEventTimestamp > 0) {
            val elapsedSeconds = ((now - lastEventTimestamp) / 1000).toInt()
            // Discard huge gaps — almost certainly a phone-asleep period
            // the OS didn't cleanly signal, not real foreground time.
            if (elapsedSeconds in 1..(6 * 3600) && !isShellPackage(previous)) {
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
        // Required override; nothing to clean up — the managers are torn
        // down in onServiceConnected/onUnbind paths instead.
        if (::launchTrackingManager.isInitialized) {
            launchTrackingManager.dispose()
            overlayManager.dismissOverlay()
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        lastPackageName = null
        lastEventTimestamp = 0
        launchTrackingManager = LaunchTrackingManager(this, ::handleNewAppLaunch)
        restrictionManager = BlockRestrictionManager(this)
        overlayManager = BlockOverlayManager(this)
        if (PolicySnapshot.isDebugBuild(this)) {
            Log.d("UlimitBlock", "service connected")
        }
        launchTrackingManager.start()
        // Tell Dart we're live: it re-pushes the policy snapshot so native
        // always evaluates against the LATEST restrictions (the service can
        // be re-enabled from OS settings after an update/reset).
        UsageEventBridge.emit("__accessibility_ready__", System.currentTimeMillis())
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        if (::launchTrackingManager.isInitialized) {
            launchTrackingManager.dispose()
            overlayManager.dismissOverlay()
        }
        return super.onUnbind(intent)
    }

    // ------------------------------------------------------------------
    // Blocking decision — Mindful's MindfulTrackerService.onNewAppLaunch
    // ------------------------------------------------------------------

    /** Home-screen/system shells are not "opened apps": their time never
     *  counts toward screen time (mirrors Dart's screen_time_filter). */
    private fun isShellPackage(pkg: String): Boolean =
        pkg == packageName ||
            pkg == "com.android.systemui" ||
            pkg == "com.miui.home" ||
            pkg == "com.oplus.launcher" ||
            pkg == "com.coloros.launcher" ||
            pkg == "com.bbk.launcher" ||
            pkg == "com.vivo.launcher" ||
            pkg == "com.hw.launcher" ||
            pkg == "com.huawei.android.launcher" ||
            pkg == "com.hihonor.launcher" ||
            pkg == "com.sec.android.app.launcher" ||
            pkg == "com.samsung.android.launcher" ||
            pkg == "org.lineageos.launcher3" ||
            pkg == "com.nothing.launcher" ||
            pkg.contains("launcher")

    /** Called whenever a new real app surfaces (accessibility fast path
     *  or the UsageStats poll). If it's blocked we show the full-screen
     *  alert overlay, then close the app (BACK, HOME if BACK didn't
     *  finish it) and return to the home screen. */
    private fun handleNewAppLaunch(pkg: String) {
        if (pkg == this.packageName) return
        if (pkg.startsWith("com.android.systemui")) return
        val state = restrictionManager.evaluate(pkg) ?: return

        // 1) Alert popup over the blocked app.
        overlayManager.showOverlay(pkg, state)

        // 2) Close the application and return to the home screen —
        //    guaranteed: performGlobalAction does not depend on the
        //    overlay rendering.
        performGlobalAction(GLOBAL_ACTION_BACK)
        handler.postDelayed({
            if (launchTrackingManager.currentForeground == pkg) {
                performGlobalAction(GLOBAL_ACTION_HOME)
            }
        }, 250)

        // 3) The alert has been on screen long enough so Home is usable.
        handler.postDelayed({ overlayManager.dismissOverlay() }, 1400)
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
        overlayManager.showSmallNotice(
            packageName = packageName,
            message = "Adult content blocked: $domain",
        )
        performGlobalAction(GLOBAL_ACTION_BACK)
    }
}
