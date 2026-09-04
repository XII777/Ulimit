package com.ulimit.app

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

/**
 * The accessibility layer of the blocking system, structured after
 * Mindful's split (accessibility = instant detection + the only legal
 * BACK/HOME actuator; a persistent service = always-on detection):
 *
 *  - Detection fast path: TYPE_WINDOW_STATE_CHANGED /
 *    TYPE_WINDOWS_CHANGED events go straight to [BlockEngine] — every
 *    event, no cross-package dedupe. The old `lastLaunchedApp` dedupe
 *    here is what silently swallowed a RE-launched blocked app (the
 *    engine's own 1.2s enforce-dedupe + recheck loop replaced it).
 *  - Actuator: the ONLY component allowed to press BACK/HOME
 *    (performGlobalAction is accessibility-only). The guard service's
 *    detector drives ejects through this when connected.
 *  - Overlay host: TYPE_ACCESSIBILITY_OVERLAY — the block pop-layer
 *    needs no "Display over other apps" permission through here.
 *  - Usage attribution: foreground seconds + Dart usage events
 *    (unchanged semantics, deduped via [lastPackageName]).
 *  - Adult-content screen scanning: browser text is scanned on
 *    TYPE_WINDOW_CONTENT_CHANGED (which the service config NOW
 *    subscribes to — previously the scan was dead code) and the
 *    browser is backed out automatically on a match.
 *
 * If this service is disabled or killed, blocking SURVIVES: the guard
 * service detects + overlays, and this service re-attaches as actuator
 * the moment the system rebinds it.
 */
class UlimitAccessibilityService : AccessibilityService(), BlockEngine.Ejector {

    // Usage tracking dedupe state.
    private var lastPackageName: String? = null
    private var lastEventTimestamp: Long = 0

    private lateinit var overlayManager: BlockOverlayManager

    // Adult-content screen scanning state: while the adult filter is
    // enabled we read the visible text of the current browser app and,
    // if it contains a domain from the blocked set, back out
    // automatically. Kept as fields so the scan debounce survives
    // across events (one scan per ~2.5s per package).
    private var lastContentScanPackage: String? = null
    private var lastContentScanAt: Long = 0

    // Feed-surface scan debounce (one detection per 1.5s per package).
    private var lastFeedScanPackage: String? = null
    private var lastFeedScanAt: Long = 0

    override fun onServiceConnected() {
        super.onServiceConnected()
        lastPackageName = null
        lastEventTimestamp = 0
        overlayManager = BlockOverlayManager(
            this,
            android.view.WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        )
        BlockEngine.attachAccessibility(overlayManager, this)

        // The guard service keeps detection + process alive; make sure
        // it's running now that enforcement is configured. Background
        // FGS-start restrictions are swallowed by ensureStarted.
        BlockGuardService.ensureStarted(this)

        // Tell Dart we're live: it re-pushes the policy snapshot so
        // native always evaluates against the LATEST restrictions (the
        // service can be re-enabled from OS settings after an
        // update/reset).
        UsageEventBridge.emit("__accessibility_ready__", System.currentTimeMillis())

        // Re-check whatever is foreground RIGHT NOW: the service can
        // (re)bind while a blocked app is already on screen — the old
        // implementation waited for the next transition, which might
        // never come.
        BlockEngine.reevaluateForeground()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> {
                // Adult-content screen scan: the content change is the
                // signal that a browser page rendered new text (URL
                // bar / page content). Debounced per package.
                scanBrowserContent(event.packageName?.toString())

                // Doomscroll feed-surface detection: a Reels/Shorts/
                // For-You surface painted or switched inside a managed
                // section-level app → count it and eject the scroll.
                scanFeedSurface(event.packageName?.toString())
            }

            AccessibilityEvent.TYPE_WINDOWS_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            -> {
                val eventPkg = event.packageName?.toString()
                // Enforcement: EVERY event, no dedupe here — the engine
                // collapses repeats and re-arms on re-entry.
                BlockEngine.onAppLaunch(
                    eventPkg ?: rootInActiveWindow?.packageName?.toString()
                )

                // Usage attribution only on full window transitions.
                if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
                    attributeUsage(eventPkg)
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Usage attribution (unchanged semantics from the old service)
    // ------------------------------------------------------------------

    private fun attributeUsage(packageName: String?) {
        if (packageName == null) return
        val now = System.currentTimeMillis()

        // Reaching Ulimit itself is only possible after the overlay was
        // already released (the Home escape hides it first), and the
        // accessibility overlay belongs to this app's package — so a
        // window-state event for our OWN window or for transient system
        // UI (notification shade / recents) must NOT tear down the
        // blocker (the engine ignores them too) and our own window only
        // closes the usage window.
        if (packageName == this.packageName) {
            UsageEventBridge.emit(packageName, now)
            return
        }
        if (packageName.startsWith("com.android.systemui")) return

        // Dedupe identical consecutive transitions.
        if (packageName == lastPackageName) return

        val previous = lastPackageName
        if (previous != null && lastEventTimestamp > 0) {
            val elapsedSeconds = ((now - lastEventTimestamp) / 1000).toInt()
            // Discard huge gaps — almost certainly a phone-asleep period
            // the OS didn't cleanly signal, not real foreground time.
            if (elapsedSeconds in 1..(6 * 3600) && !BlockEngine.isShellPackage(previous)) {
                PolicySnapshot.addForegroundSeconds(this, previous, elapsedSeconds)
            }
        }
        lastPackageName = packageName
        lastEventTimestamp = now

        // Doomscroll open counting: entering one of the infinite-feed
        // platforms is one "reel/shorts open" — counted natively so a
        // daily opens budget bites even with Ulimit swiped away.
        if (DoomscrollApps.isDoomscrollPackage(packageName)) {
            PolicySnapshot.addDoomscrollOpen(this, packageName)
        }

        // Doomscroll open counting: entering a feed-native doomscroll
        // app (Reddit etc.) is one feed open — counted natively so a
        // daily budget bites even with Ulimit swiped away.
        // Section-level apps (Instagram, YouTube…) are counted by the
        // feed-surface detector, not on app entry.
        if (DoomscrollApps.isFeedNativePackage(packageName)) {
            PolicySnapshot.addDoomscrollOpen(this, packageName)
        }

        // Forward the transition to Dart (which owns the authoritative
        // SQLite usage history and pickup counting). Native emits the
        // *new* package; Dart attributes elapsed time itself.
        UsageEventBridge.emit(packageName, now)
    }

    // ------------------------------------------------------------------
    // Doomscroll feed-surface detection (section-level platforms)
    //
    // Whole-app blocking would take away DMs, search, profiles… —
    // everything BUT the scroll. So for Instagram (Reels), YouTube
    // (Shorts), TikTok (For You) etc. we detect the feed SURFACE
    // itself from the visible node tree (the same technique as the
    // browser text scan) and eject only that: notice + BACK. The rest
    // of the app stays fully usable.
    // ------------------------------------------------------------------

    /** Last package whose surface was actively "in a feed" — a back
     *  press from outside a feed would otherwise be misattributed. */
    private var feedSurfacePackage: String? = null

    private fun scanFeedSurface(packageName: String?) {
        if (packageName == null) return
        if (!DoomscrollApps.isSectionLevelPackage(packageName)) return

        val snapshot = PolicySnapshot.read(this) ?: return

        // Active during a focus session with the doomscroll flag, or
        // outright for 0-budget section platforms.
        val sessionFlag = snapshot.focus?.blockDoomscroll == true &&
            snapshot.focus.untilMillis > System.currentTimeMillis()
        val outright = packageName in snapshot.doomscrollSection &&
            (snapshot.doomscrollFeeds[packageName] ?: -1) == 0
        if (!sessionFlag && !outright) {
            if (feedSurfacePackage == packageName) feedSurfacePackage = null
            return
        }

        // Debounce: content events fire continuously while a video
        // plays/scrolls. One detection per 1.5s per package.
        val now = System.currentTimeMillis()
        if (packageName == lastFeedScanPackage && now - lastFeedScanAt < 1500) return
        lastFeedScanPackage = packageName
        lastFeedScanAt = now

        val markers = DoomscrollApps.feedMarkersFor(packageName)
        if (markers.isEmpty()) return
        val requireSelected = DoomscrollApps.markersRequireSelectedFor(packageName)

        if (feedSurfacePresent(markers, requireSelected)) {
            feedSurfacePackage = packageName
            // One feed open per surfaced scroll — bridged to Dart's
            // authoritative DB via the sentinel event channel.
            PolicySnapshot.addDoomscrollOpen(this, packageName)
            UsageEventBridge.emit(
                UlimitSentinel.doomOpenPrefix + packageName,
                now
            )
            overlayManager.showSmallNotice(
                packageName = packageName,
                message = "Feed blocked — the rest of the app stays usable",
            )
            pressBack()
        } else if (feedSurfacePackage == packageName) {
            // Left the feed surface on our own eject or theirs.
            feedSurfacePackage = null
        }
    }

    /** True when any marker text is visible in the active window. When
     *  [requireSelected], the marker node must also be SELECTED — tab
     *  labels exist for unselected tabs too, and "Reels" appearing in
     *  a caption must not count. */
    private fun feedSurfacePresent(markers: List<String>, requireSelected: Boolean): Boolean {
        return try {
            val root = rootInActiveWindow ?: return false
            var found = false
            var nodes = 0
            fun walk(node: android.view.accessibility.AccessibilityNodeInfo?) {
                if (node == null || found || nodes > 500) return
                nodes++
                try {
                    val selected = node.isSelected
                    val texts = buildList {
                        node.text?.toString()?.let { add(it) }
                        node.contentDescription?.toString()?.let { add(it) }
                    }
                    for (t in texts) {
                        val matched = markers.any { t.contains(it, ignoreCase = true) }
                        if (matched && (!requireSelected || selected)) {
                            found = true
                            return
                        }
                    }
                    for (i in 0 until node.childCount) {
                        walk(node.getChild(i) ?: continue)
                        if (found) return
                    }
                } catch (_: Exception) {
                    // Node detached mid-walk.
                } finally {
                    try {
                        node.recycle()
                    } catch (_: Exception) {
                    }
                }
            }
            walk(root)
            found
        } catch (_: Exception) {
            false
        }
    }

    // ------------------------------------------------------------------
    // BlockEngine.Ejector — the only legal BACK/HOME presser
    // ------------------------------------------------------------------

    override fun pressBack() {
        try {
            performGlobalAction(GLOBAL_ACTION_BACK)
        } catch (_: Exception) {
        }
    }

    override fun pressHome() {
        try {
            performGlobalAction(GLOBAL_ACTION_HOME)
        } catch (_: Exception) {
        }
    }

    override fun activeWindowPackage(): String? =
        try {
            rootInActiveWindow?.packageName?.toString()
        } catch (_: Exception) {
            null
        }

    override fun onInterrupt() {
        // Required override; nothing to clean up — detach happens in
        // onUnbind/onDestroy paths.
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        BlockEngine.detachAccessibility(this)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        BlockEngine.detachAccessibility(this)
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // Adult-content screen scanning (belt & braces for the DNS filter):
    // while the adult block-list is enabled, the visible text of the
    // foreground browser (URL bar + page) is scanned and — if a domain
    // from the blocked set is present — the browser is backed out
    // automatically with a one-time notice. Bounded by design: at most
    // one scan per package per ~2.5s, a node/text budget, and cheap
    // substring matching.
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
        pressBack()
    }
}
