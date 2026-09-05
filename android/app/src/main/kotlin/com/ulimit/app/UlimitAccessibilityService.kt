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

    companion object {
        /// Live instance while the service is bound — lets the screen-off
        /// forwarder close the native usage session at the exact moment
        /// Digital Wellbeing stops counting.
        @Volatile
        var instance: UlimitAccessibilityService? = null
            private set
    }

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

    /** Last feed-surface ejection time — debounces the notice+BACK so
     *  a re-asserting surface cannot spam the user. */
    private var lastFeedEjectAt: Long = 0

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        lastPackageName = null
        lastEventTimestamp = 0
        overlayManager = BlockOverlayManager(
            this,
            android.view.WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        )
        BlockEngine.attachAccessibility(overlayManager, this)

        // FORCE the event subscription the feed detector needs. Android
        // caches the service's ServiceInfo (built from the XML) at the
        // moment the accessibility service is (re)enabled — OEMs like
        // ColorOS keep serving the OLD cached config after an app
        // update, so TYPE_VIEW_SCROLLED never arrives and the doomscroll
        // detector sees nothing (the "it never counts a single scroll"
        // failure). We read the CURRENT info (so the XML's
        // canRetrieveWindowContent etc. survive — that one has no
        // programmatic setter at all) and re-publish it with the event
        // types/flags we need added.
        try {
            val info = serviceInfo ?: android.accessibilityservice.AccessibilityServiceInfo()
            info.eventTypes = info.eventTypes or
                android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                android.view.accessibility.AccessibilityEvent.TYPE_WINDOWS_CHANGED or
                android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or
                android.view.accessibility.AccessibilityEvent.TYPE_VIEW_SCROLLED
            info.flags = info.flags or
                android.accessibilityservice.AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
                android.accessibilityservice.AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            info.feedbackType = android.accessibilityservice.AccessibilityServiceInfo.FEEDBACK_GENERIC
            info.notificationTimeout = 100
            serviceInfo = info
            DiagnosticsMarkers.serviceInfoForced = true
        } catch (_: Exception) {
            DiagnosticsMarkers.serviceInfoForced = false
        }

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

            // Scroll events — the doomscroll detector's PRIMARY signal
            // (Friction's exact model): a 600ms gap between scrolls
            // marks a new scroll session, and a scroll session IS a
            // feed open. This counts live and enforces budgets with NO
            // reliance on the node-tree markers, which proved unreliable
            // on this device's app versions.
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> {
                val now = System.currentTimeMillis()
                DiagnosticsMarkers.scrollEventsSeen++
                DiagnosticsMarkers.lastScrollEventAt = now
                val eventPkg = event.packageName?.toString() ?: return
                val section = DoomscrollApps.isSectionLevelPackage(eventPkg)
                // Feed-native apps (Reddit, Pinterest…) count live scrolls
                // too — their budget exhausts the whole-app block via the
                // engine, so the only section-specific part here is the
                // eject (backs the user out of the reels surface).
                if (section || DoomscrollApps.isFeedNativePackage(eventPkg)) {
                    DiagnosticsMarkers.sectionScrollEventsSeen++
                    DiagnosticsMarkers.lastSectionScrollAt = now
                    DiagnosticsMarkers.lastSectionScrollPkg = eventPkg

                    val newSession = doomScrollPkg != eventPkg ||
                        now - doomScrollLastAt > DOOM_SCROLL_SESSION_GAP_MS
                    doomScrollPkg = eventPkg
                    doomScrollLastAt = now

                    if (newSession) {
                        DiagnosticsMarkers.scrollSessions++
                        DiagnosticsMarkers.lastScrollSessionAt = now
                        // Every scroll session is one live feed open —
                        // the app's counter ticks WHILE the user
                        // scrolls. recordDoomOpen's short dedupe window
                        // guarantees one count per burst even when the
                        // marker path sees the same fling.
                        recordDoomOpen(eventPkg, now, viaScroll = true)
                    }
                    // Keep the feed session warm for content-change scans.
                    scrollSessionPkg = eventPkg
                    scrollSessionLastAt = now
                    if (section) {
                        // Enforce continuously while scrolling — the
                        // user can't keep doomscrolling a blocked feed
                        // even if every marker missed.
                        ejectFeedIfBlocked(eventPkg, now)
                    }
                }
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
        DiagnosticsMarkers.lastAccessibilityEventAt = now

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
            // Gaps beyond 15 minutes are never attributed — a missed
            // screen-off, a dead service or a frozen process would
            // otherwise dump hours of phantom foreground time onto the
            // last app (the multi-hour over-count class). The OS sync
            // owns the real totals; this accumulator only feeds native
            // enforcement.
            if (elapsedSeconds in 1..(15 * 60) && !BlockEngine.isShellPackage(previous)) {
                PolicySnapshot.addForegroundSeconds(this, previous, elapsedSeconds)
            } else if (elapsedSeconds > 15 * 60) {
                DiagnosticsMarkers.gapDiscards++
            }
        }
        lastPackageName = packageName
        lastEventTimestamp = now

        // Doomscroll open counting, single source: feed-native apps
        // (Reddit etc.) count their foreground ENTRY — their whole app
        // IS the feed, so a visit without scrolling still consumed the
        // budget (guarded so a just-past scroll session doesn't make
        // the entry a second open). Section-level apps (Instagram,
        // YouTube…) are counted by scroll sessions / surface sightings
        // only. All paths go through recordDoomOpen so native budget +
        // Dart DB + diagnostics update as one unit.
        if (DoomscrollApps.isFeedNativePackage(packageName)) {
            val lastOpen = lastDoomOpenAtByPkg[packageName] ?: 0L
            if (now - lastOpen > 5_000L) {
                recordDoomOpen(packageName, now, viaScroll = false, minGapMs = 5_000L)
            }
        }

        // Forward the transition to Dart (which owns the authoritative
        // SQLite usage history and pickup counting). Native emits the
        // *new* package; Dart attributes elapsed time itself.
        UsageEventBridge.emit(packageName, now)
    }

    /**
     * Closes the open native usage session as of NOW. Called by the
     * screen-state forwarder on ACTION_SCREEN_OFF so the native-side
     * tracker (which keeps counting when the Dart engine is down)
     * stops attributing locked-screen time too — the framework's own
     * pause event covers the same moment in the OS numbers.
     */
    fun closeUsageSession() {
        val pkg = lastPackageName ?: return
        val now = System.currentTimeMillis()
        val elapsedSeconds = ((now - lastEventTimestamp) / 1000).toInt()
        if (elapsedSeconds in 1..(6 * 3600) && !BlockEngine.isShellPackage(pkg)) {
            PolicySnapshot.addForegroundSeconds(this, pkg, elapsedSeconds)
        }
        lastPackageName = null
        lastEventTimestamp = 0
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

    /** Open scroll session: when the user's last in-feed scroll was
     *  recent, they are considered INSIDE the feed. Scrolling IS the
     *  feed — no UI-tree markers needed (they proved unreliable on
     *  this device: app versions render the feed without the labels
     *  we look for). */
    private var scrollSessionPkg: String? = null
    private var scrollSessionLastAt: Long = 0

    /** A scroll session ends after this long with no in-feed scroll. */
    private val SCROLL_SESSION_TIMEOUT_MS = 20_000L

    /** Raw scroll-session grouping (Friction's model): scrolls less than
     *  [DOOM_SCROLL_SESSION_GAP_MS] apart are ONE browsing session —
     *  one "scroll". A new session inside a managed app records one
     *  live feed open: the app's counters tick WHILE the user scrolls. */
    private val DOOM_SCROLL_SESSION_GAP_MS = 600L
    private var doomScrollPkg: String? = null
    private var doomScrollLastAt: Long = 0

    /** Idle watching (feed visible, zero scrolling) still accrues
     *  doomscroll credit — but slowly: one open per this interval at
     *  most, so a 20-minute Shorts-watch session counts ~10 rather
     *  than thousands. */
    private val DOOM_WATCH_RECOUNT_MS = 120_000L

    /** Per-package last-recorded open time — dedupes the two detection
     *  paths (scroll sessions + marker surface appearances) so one
     *  fling burst or one paint storm counts exactly once. */
    private val lastDoomOpenAtByPkg = HashMap<String, Long>()

    /**
     * Record ONE doomscroll "open" (the live unit: a scroll session, or
     * a newly-visible feed surface when the user isn't scrolling — auto-
     * play). Writes the native daily budget counter AND emits the
     * `__doom_open__:` sentinel, so Dart's SQLite + the watched streams
     * update the Doomscroll screen and the notification chip the same
     * instant — the "live update" behavior.
     */
    private fun recordDoomOpen(
        packageName: String,
        now: Long,
        viaScroll: Boolean,
        minGapMs: Long = DOOM_SCROLL_SESSION_GAP_MS,
    ) {
        val snapshot = PolicySnapshot.read(this) ?: return
        // Only managed packages (or focus sessions blocking everything).
        if (snapshot.doomscrollFeeds[packageName] == null &&
            !(snapshot.focus?.let { it.blockDoomscroll && it.untilMillis > now } == true)
        ) return
        // Short dedupe window: the marker path and the scroll path may
        // see the same burst within milliseconds of each other.
        val last = lastDoomOpenAtByPkg[packageName] ?: 0L
        if (now - last < minGapMs) return
        lastDoomOpenAtByPkg[packageName] = now

        PolicySnapshot.addDoomscrollOpen(this, packageName)
        DiagnosticsMarkers.doomOpens++
        DiagnosticsMarkers.lastDoomOpenAt = now
        DiagnosticsMarkers.lastDoomOpenPkg = packageName
        if (viaScroll) DiagnosticsMarkers.doomOpenViaScroll++
        UsageEventBridge.emit(
            "__doom_open__:" + packageName,
            now
        )
        // Refresh the notification chip straight from the detector —
        // the Dart side only sees sentinels while its EventChannel is
        // attached, but a scrolling counter must tick on the chip even
        // when the app was swiped away.
        FocusIndicatorService.pushDoomState(
            this,
            packageName,
            PolicySnapshot.doomscrollCounts(this)[packageName] ?: 0,
        )
    }

    /** True while [packageName]'s feed should be blocked right now:
     *  focus session flag, budget 0, or the daily opens already spent.
     *  (The old gate made detection wait for blocking while blocking
     *  waited for detection — circular; rules are resolved here
     *  independently of any detection now.) */
    private fun feedBlockedNow(packageName: String, snapshot: PolicySnapshot.Snapshot?): Boolean {
        val snap = snapshot ?: return false
        val now = System.currentTimeMillis()
        val focus = snap.focus
        val sessionFlag = focus != null && focus.blockDoomscroll &&
            focus.untilMillis > now
        val budget = snap.doomscrollFeeds[packageName]
        val used = PolicySnapshot.doomscrollCounts(this)[packageName] ?: 0
        val outright = packageName in snap.doomscrollSection && budget == 0
        val overBudget = budget != null && budget > 0 && used >= budget
        return sessionFlag || outright || overBudget
    }

    /** Notice + BACK for a blocked feed, debounced 2.5s so a
     * re-asserting surface can't spam. Callers reach this from EVERY
     * scroll inside a managed feed — enforcement no longer depends on
     * the node-tree markers matching. */
    private fun ejectFeedIfBlocked(packageName: String, now: Long) {
        val snapshot = PolicySnapshot.read(this) ?: return
        if (!feedBlockedNow(packageName, snapshot)) return
        if (now - lastFeedEjectAt < 2500) return
        lastFeedEjectAt = now
        DiagnosticsMarkers.feedEjects++
        DiagnosticsMarkers.lastFeedEjectAt = now
        DiagnosticsMarkers.lastFeedEjectPkg = packageName
        val appName = try {
            val info = packageManager.getApplicationInfo(packageName, 0)
            packageManager.getApplicationLabel(info)?.toString() ?: packageName
        } catch (_: Exception) {
            packageName
        }
        // Bottom toast + exit (the app keeps working above it) — the
        // top badge treatment was replaced by request.
        overlayManager.showBottomToast("$appName — daily feed limit reached")
        pressBack()
    }

    private fun scanFeedSurface(packageName: String?) {
        if (packageName == null) return
        if (!DoomscrollApps.isSectionLevelPackage(packageName)) return

        val snapshot = PolicySnapshot.read(this) ?: return

        val now = System.currentTimeMillis()

        // Scroll session tracking: the TYPE_VIEW_SCROLLED handler
        // refreshes scrollSessionLastAt on every in-feed scroll, so a
        // still-warm session means "the user is inside this feed".
        // Content-change events (watching without scrolling) keep the
        // session alive via the marker hit or the unexpired timer.
        val sessionWarm = scrollSessionPkg == packageName &&
            now - scrollSessionLastAt <= SCROLL_SESSION_TIMEOUT_MS

        // Debounce for the UI-tree scan (cheap supplement to scrolls).
        val scanDebounced = packageName == lastFeedScanPackage &&
            now - lastFeedScanAt < 1500
        if (!scanDebounced) {
            lastFeedScanPackage = packageName
            lastFeedScanAt = now
            DiagnosticsMarkers.feedScans++
            DiagnosticsMarkers.lastFeedScanAt = now
            DiagnosticsMarkers.lastFeedScanPkg = packageName
        }

        // In-feed = a recent scroll OR the marker tree confirming the
        // feed surface (markers can also confirm an entry the scrolls
        // missed — watching without touching).
        val markers = DoomscrollApps.feedMarkersFor(packageName)
        val markerHit = if (markers.isEmpty()) false else {
            val requireSelected = DoomscrollApps.markersRequireSelectedFor(packageName)
            feedSurfacePresent(markers, requireSelected).also {
                if (it) {
                    DiagnosticsMarkers.feedSurfaceHits++
                    DiagnosticsMarkers.lastFeedSurfaceHitAt = now
                }
            }
        }
        val inFeed = sessionWarm || markerHit
        feedSurfacePackage = if (inFeed) packageName else null
        if (!inFeed) return

        if (feedBlockedNow(packageName, snapshot)) {
            ejectFeedIfBlocked(packageName, now)
        } else if (markerHit) {
            // Marker path: a visible feed surface WITHOUT a live scroll
            // (watching Shorts autoplay, idle LFR content) still counts
            // as ongoing doomscrolling — but at a slow 2-minute cadence,
            // since the user isn't actively scrolling. Scroll sessions
            // carry the fast, live counting.
            val watchAge = now - (lastDoomOpenAtByPkg[packageName] ?: 0L)
            if (watchAge >= DOOM_WATCH_RECOUNT_MS) {
                recordDoomOpen(packageName, now, viaScroll = false)
            }
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
        instance = null
        // Tell Dart tracking just stopped — the open usage session must
        // be dropped there, otherwise its pending counter keeps growing
        // with no events ever arriving to close it.
        UsageEventBridge.emit(UsageEventBridge.ACCESSIBILITY_DOWN, System.currentTimeMillis())
        BlockEngine.detachAccessibility(this)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
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

    // Cached blocked-domain set, invalidated when the file changes on
    // disk (Dart rewrites it atomically on every rule change). Loading
    // 100k+ lines per content event would stall the accessibility UI
    // thread, so this must never be unconditional.
    private var cachedDomains: Set<String>? = null
    private var cachedDomainsStamp: Long = -1

    private fun loadScanDomains(): Set<String> {
        return try {
            val file = java.io.File(filesDir, "blocked_domains.txt")
            if (!file.exists()) {
                cachedDomains = emptySet()
                emptySet()
            } else {
                val stamp = file.lastModified()
                val cached = cachedDomains
                if (cached != null && stamp == cachedDomainsStamp) {
                    cached
                } else {
                    val loaded = file.readLines()
                        .asSequence()
                        .map { it.trim().lowercase() }
                        .filter { it.isNotEmpty() }
                        .toSet()
                    cachedDomains = loaded
                    cachedDomainsStamp = stamp
                    loaded
                }
            }
        } catch (_: Exception) {
            emptySet()
        }
    }

    private fun scanBrowserContent(packageName: String?) {
        if (packageName == null) return

        // Run whenever ANY website blocking is configured (the domain
        // file is the shared source of truth — custom rules, the adult
        // category, every category). The old gate required the adult
        // flag specifically, so custom-blocked sites were silently
        // ignored when the VPN was off — the browser scan is the ONLY
        // no-VPN enforcement path.
        val snapshot = PolicySnapshot.read(this) ?: return
        val domains = loadScanDomains()
        if (domains.isEmpty()) return
        // The browser check is prefix-tolerant: nightlies/betas/forks
        // (com.brave.browser_nightly) inherit their base package's
        // entry. Exact-match missed real browsers on this device.
        if (packageName !in snapshot.browserPackages &&
            snapshot.browserPackages.none { packageName.startsWith(it) }
        ) return

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
        BrowserScanMarkers.scans++
        BrowserScanMarkers.lastScanAt = now
        BrowserScanMarkers.lastScanPkg = packageName
        BrowserScanMarkers.domainCount = domains.size

        val text = collectVisibleText()
        if (text.isEmpty()) return

        for (match in FQDN_REGEX.findAll(text)) {
            val candidate = match.value.lowercase().trimEnd('.')
            val matched = domains.firstOrNull { candidate == it || candidate.endsWith(".$it") }
            if (matched != null) {
                BrowserScanMarkers.blocks++
                BrowserScanMarkers.lastBlockAt = now
                BrowserScanMarkers.lastBlockDomain = candidate
                // Full block PAGE (not a back + toast): names the
                // filter that caught it and the app, then the user
                // leaves via Back/Stay themselves.
                onBlockedDomainInBrowser(packageName, candidate, sourceOf(matched))
                return
            }
        }
    }

    /** Label of the filter behind [domain] — custom block, or the
     *  human category name from the sibling sources map file. */
    private fun sourceOf(domain: String): String {
        try {
            val file = java.io.File(filesDir, "blocked_domain_sources.txt")
            if (!file.exists()) return "Ulimit block list"
            if (fileSourcesStamp != file.lastModified()) {
                fileSourcesStamp = file.lastModified()
                cachedSources = file.readLines()
                    .mapNotNull { line ->
                        val i = line.indexOf('|')
                        if (i <= 0) null
                        else line.substring(0, i).trim().lowercase() to
                            line.substring(i + 1).trim()
                    }
                    .toMap()
            }
            return cachedSources[domain] ?: "Ulimit block list"
        } catch (_: Exception) {
            return "Ulimit block list"
        }
    }

    private var fileSourcesStamp = -1L
    private var cachedSources: Map<String, String> = emptyMap()

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

    private fun onBlockedDomainInBrowser(packageName: String, domain: String, source: String) {
        // Back out + a BOTTOM toast naming the domain and the exact
        // filter that caught it (custom rule / category). The full-page
        // takeover was removed by request — the page behind simply
        // never appears.
        overlayManager.showBottomToast(
            "Blocked · $domain — by $source",
        )
        pressBack()
    }
}
