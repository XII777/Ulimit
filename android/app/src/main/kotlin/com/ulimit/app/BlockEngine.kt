package com.ulimit.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * The single blocking brain — every foreground candidate from every
 * detector converges here, and every enforcement action originates here.
 *
 * Detectors (redundant by design):
 *  - [UlimitAccessibilityService] — TYPE_WINDOW_STATE_CHANGED /
 *    TYPE_WINDOWS_CHANGED events: instant (<100ms), needs only the
 *    accessibility toggle. Also the ONLY actuator that can press
 *    BACK/HOME (performGlobalAction is an accessibility-only API).
 *  - [BlockGuardService] — UsageStatsManager event poll every 750ms in
 *    a persistent foreground service: keeps working when the
 *    accessibility service is disabled, reset by an app update, or
 *    killed by an aggressive OEM. Also keeps the process alive so the
 *    accessibility service cannot be quietly reaped.
 *
 * Neither detector alone is trusted: both feed [onAppLaunch], which
 * evaluates against the persisted [PolicySnapshot] (no VPN, no Dart,
 * no UI required) and drives a relentless eject loop — the exact
 * pattern Mindful/ScreenZen-class blockers converge on:
 *
 *  1. blocked app surfaces  → full-screen pop-layer overlay + BACK,
 *  2. re-verify every 400ms→1.5s while the SAME app is foreground:
 *     still blocked → HOME, overlay stays up,
 *  3. foreground moved to anything else (launcher, allowed app) →
 *     overlay is dismissed and the loop stops.
 *
 * The old implementation's failure mode — a re-launch of the same
 * blocked app being deduped away because `lastLaunchedApp` still held
 * its package, and the overlay self-dismissing after a fixed 1400ms
 * even when the eject failed — cannot happen here: repeated events for
 * the same package re-arm enforcement, and the overlay lives exactly
 * as long as the blocked app is foreground.
 */
object BlockEngine {

    /** BACK/HOME presser + focused-window probe. Implemented by the
     *  accessibility service; absent whenever it is not connected. */
    interface Ejector {
        fun pressBack()
        fun pressHome()

        /** Package of the window that currently owns input focus — the
         *  most truthful foreground probe, ~0 latency. */
        fun activeWindowPackage(): String?
    }

    private const val TAG = "UlimitBlock"

    /** Backoff schedule (ms) for post-eject re-verification. */
    private val RECHECK_DELAYS = longArrayOf(400, 900, 1600, 2600, 4000)
    private const val RECHECK_LATER_MS = 1500L

    /** Hard cap on slow rechecks: after ~35s of the same blocked app
     *  refusing to die we stop re-ejecting (the overlay remains up so
     *  the app is still unusable) instead of looping forever. */
    private const val MAX_LATER_RECHECKS = 20

    private val handler = Handler(Looper.getMainLooper())

    private var appContext: Context? = null

    @Volatile private var ejector: Ejector? = null

    /** Overlay host owned by the accessibility service (no extra
     *  permission needed — TYPE_ACCESSIBILITY_OVERLAY). */
    @Volatile private var a11yOverlay: BlockOverlayManager? = null

    /** Overlay host owned by the guard service (TYPE_APPLICATION_OVERLAY,
     *  needs "Display over other apps") — the fallback so blocking still
     *  covers the screen when accessibility is off. */
    @Volatile private var guardOverlay: BlockOverlayManager? = null

    /** Live foreground tracker from the guard service's UsageEvents poll. */
    @Volatile private var trackedForeground: () -> String? = { null }

    // --- enforcement loop state (main thread only) ---
    private var enforcedPkg: String? = null

    // No auto-eject countdown: the block screen stays until the user
    // taps Close (or backs out). There is no timer to track.
    private var recheckStep = 0
    private var laterRechecks = 0
    private val recheckRunnable = Runnable { recheck() }

    // --- diagnostics ring buffer (mirrors the debug log) ---
    private val diagEvents = ArrayDeque<String>()
    private const val DIAG_MAX = 60
    private var lastBlockedPkg: String? = null
    private var lastBlockedAt = 0L

    private fun diag(message: String) {
        synchronized(diagEvents) {
            diagEvents.addLast(java.lang.String.format("%tT ", java.util.Date()) + message)
            while (diagEvents.size > DIAG_MAX) diagEvents.removeFirst()
        }
        appContext?.let { if (PolicySnapshot.isDebugBuild(it)) Log.d(TAG, message) }
    }

    /** Snapshot of the engine's live state + recent events, for the
     *  in-app diagnostics screen. */
    fun diagnostics(context: Context): String {
        val sb = StringBuilder()
        val snapshot = PolicySnapshot.read(context)
        sb.append("snapshot: ${if (snapshot == null) "MISSING" else "pushed ${java.util.Date(snapshot.pushedAtMillis)}"}\n")
        sb.append("policy: ${if (PolicySnapshot.hasActivePolicy(context)) "active" else "none"}\n")
        sb.append("blockedNow: ${snapshot?.blockedNow?.keys?.joinToString() ?: "-"}\n")
        sb.append("manual: ${snapshot?.manual?.joinToString { it.pkg }?.ifEmpty { "-" } ?: "-"}\n")
        sb.append("a11y actuator: ${if (ejector != null) "yes" else "NO"}\n")
        sb.append("a11y overlay: ${if (a11yOverlay != null) "ready" else "-"}\n")
        sb.append("guard service: ${if (BlockGuardService.isRunning) "running" else "NOT RUNNING"}\n")
        sb.append("guard overlay: ${guardOverlay?.let { if (it.canShow) "ready" else "no permission" } ?: "-"}\n")
        sb.append("poll foreground: ${trackedForeground() ?: "unknown"}\n")
        sb.append("enforcing: ${enforcedPkg ?: "nothing"}\n")
        sb.append(
            "grace: " + when {
                enforcedPkg == null -> "-"
                else -> "none (manual close)"
            } + "\n"
        )
        sb.append("last block: ${lastBlockedPkg?.let { "$it @ %tT".format(java.util.Date(lastBlockedAt)) } ?: "never"}\n")
        sb.append("--- recent events ---\n")
        synchronized(diagEvents) {
            for (e in diagEvents.asReversed()) sb.append(e).append('\n')
        }
        // Ground truth: the exact persisted snapshot. If blockedNow/manual
        // look like quoted Java toString output here, the write path is
        // broken; if they're real JSON, parse is broken.
        val raw = PolicySnapshot.prefs(context).getString(PolicySnapshot.KEY_SNAPSHOT, null)
        sb.append("raw snapshot: ${raw?.take(700) ?: "-"}\n")
        return sb.toString()
    }

    /** Called once from [UlimitApplication.onCreate]. */
    fun init(context: Context) {
        appContext = context.applicationContext
    }

    // ------------------------------------------------------------------
    // Wiring (both services run in this app's process)
    // ------------------------------------------------------------------

    fun attachAccessibility(overlay: BlockOverlayManager, ejector: Ejector) {
        this.ejector = ejector
        this.a11yOverlay = overlay
        diag("a11y actuator attached")
    }

    fun detachAccessibility(ejector: Ejector) {
        if (this.ejector === ejector) {
            diag("a11y actuator detached")
            this.ejector = null
            this.a11yOverlay = null
            // The system tears the service's overlay windows down with
            // it; state resets so the guard can take over cleanly.
            enforcedPkg = null
            handler.removeCallbacks(recheckRunnable)
        }
    }

    fun attachGuard(overlay: BlockOverlayManager, foreground: () -> String?) {
        this.guardOverlay = overlay
        this.trackedForeground = foreground
    }

    fun detachGuard(overlay: BlockOverlayManager) {
        if (this.guardOverlay === overlay) {
            this.guardOverlay = null
            this.trackedForeground = { null }
        }
    }

    // ------------------------------------------------------------------
    // Detection entry point — called for EVERY foreground candidate
    // from either detector. Hops to the main thread (overlay + global
    // action APIs are main-thread only; accessibility events already
    // arrive there, the poll does not).
    // ------------------------------------------------------------------

    fun onAppLaunch(pkg: String?) {
        if (pkg.isNullOrEmpty()) return
        // Cheap pre-filter for pure no-ops (evaluate ignores them too):
        // our own windows and system UI can fire at very high frequency.
        val ctx = appContext
        if (ctx != null && pkg == ctx.packageName) return
        if (pkg.startsWith("com.android.systemui")) return
        handler.post { evaluate(pkg) }
    }

    /** Re-evaluate whatever is foreground right now — used on unlock,
     *  on accessibility (re)connect and right after a snapshot push, so
     *  a block added mid-session bites instantly. */
    fun reevaluateForeground() {
        val fg = ejector?.activeWindowPackage() ?: trackedForeground() ?: return
        onAppLaunch(fg)
    }

    fun onScreenOff() {
        handler.post {
            // Nothing is visible; drop the loop + overlay. Unlock
            // re-evaluates (see onUnlocked).
            settle()
        }
    }

    fun onUnlocked() {
        reevaluateForeground()
    }

    // ------------------------------------------------------------------
    // Decision + enforcement (main thread)
    // ------------------------------------------------------------------

    private fun evaluate(pkg: String) {
        val context = appContext ?: return

        // Never enforce against ourselves and never treat system UI as
        // a usage boundary. Our own windows surfacing must not tear
        // down an active block overlay either (bypass route in the old
        // code) — just ignore them.
        if (pkg == context.packageName) return
        if (pkg.startsWith("com.android.systemui")) return

        // Home-screen shells are never "opened apps": reaching the
        // launcher means the user escaped — release the overlay.
        if (isShellPackage(pkg)) {
            settle()
            return
        }

        val now = System.currentTimeMillis()
        val verdict = PolicySnapshot.shouldBlock(context, pkg, now)
        if (verdict != null) {
            diag("BLOCKED $pkg (${verdict.reason}) -> enforce")
            enforce(pkg, verdict)
        } else {
            settle()
        }
    }

    private fun enforce(pkg: String, verdict: PolicySnapshot.BlockVerdict) {
        // Already enforcing this package: whether the sheet's grace
        // countdown is running or the post-grace verification loop is
        // ejecting, repeated events for the SAME package must never
        // restart the countdown (a fresh 10s every interaction would
        // defeat the block) nor double-eject. A new grace cycle only
        // starts after settle() clears the enforcement state.
        if (pkg == enforcedPkg) return

        // Different app (or re-arm after settle): drop the old sheet.
        if (enforcedPkg != null) settle()

        val now = System.currentTimeMillis()
        enforcedPkg = pkg
        recheckStep = 0
        laterRechecks = 0
        lastBlockedPkg = pkg
        lastBlockedAt = now

        val a11y = a11yOverlay
        val guard = guardOverlay
        val ejectAction: () -> Unit = { onGraceEnded(pkg, userInitiated = true) }

        var shown = false
        if (a11y != null) {
            shown = a11y.showOverlay(pkg, verdict, ejectAction)
        }
        if (!shown && guard != null && guard.canShow) {
            shown = guard.showOverlay(pkg, verdict, ejectAction)
        }
        diag("screen shown=$shown for $pkg (${verdict.reason})")

        if (!shown) {
            // No overlay host can draw: eject immediately (BACK first
            // with the accessibility actuator), surface a heads-up
            // notification, and keep the recheck loop verifying so a
            // stubborn app still gets re-ejected with HOME.
            diag("no overlay host — immediate eject + notify")
            val ejector = ejector
            if (ejector != null) ejector.pressBack() else if (guard?.canShow == true) {
                BlockGuardService.goHome(context())
            }
            BlockGuardService.notifyBlocked(context() ?: return, pkg)
            recheckStep = 0
            laterRechecks = 0
            scheduleRecheck(0)
            return
        }
    }

    /** The user tapped Close (or backed out): eject the blocked app,
     *  then keep the verification loop running until the foreground
     *  genuinely leaves it. */
    private fun onGraceEnded(pkg: String, userInitiated: Boolean) {
        if (enforcedPkg != pkg) return
        diag(if (userInitiated) "user tapped close — eject" else "grace ended — eject")
        val ejector = ejector
        if (ejector != null) {
            ejector.pressBack()
        } else if (guardOverlay?.canShow == true) {
            BlockGuardService.goHome(context())
        } else {
            BlockGuardService.notifyBlocked(context() ?: return, pkg)
        }
        // The screen stays up while the loop verifies; it is dismissed
        // the moment the foreground moves off the app.
        recheckStep = 0
        laterRechecks = 0
        scheduleRecheck(0)
    }

    private fun recheck() {
        val pkg = enforcedPkg ?: return
        val context = appContext ?: return

        var fg = ejector?.activeWindowPackage()
        // CRITICAL: our own windows say nothing about the blocked app.
        // While the accessibility overlay covers the screen it can
        // surface as the "active" window (its package = ours), and
        // treating that as "foreground moved" would dismiss the block
        // instantly — the blocked app usable again, blocking looking
        // dead. When the probe reports our own package (or nothing),
        // fall back to the UsageEvents tracker.
        if (fg == null || fg == context.packageName) {
            fg = trackedForeground()
        }
        if (fg == null || fg.startsWith("com.android.systemui")) {
            // In a transition — wait for the next tick without acting.
            scheduleNext()
            return
        }
        if (fg != pkg) {
            // User escaped to launcher / another app. Release.
            settle()
            return
        }

        // Blocked app is STILL foreground: verify the block is still
        // real (it may have just expired) and re-eject.
        val verdict = PolicySnapshot.shouldBlock(context, pkg, System.currentTimeMillis())
        if (verdict == null) {
            settle()
            return
        }

        // Keep the pop-layer honest and in place (same package → the
        // sheet is already up; no countdown restart)…
        showOverlay(pkg, verdict)
        // …then eject harder. BACK was already tried; HOME closes even
        // apps that swallow BACK. Repeated HOME presses are idempotent.
        val ejector = ejector
        if (ejector != null) {
            diag("still foreground — re-eject HOME (a11y)")
            ejector.pressHome()
        } else if (guardOverlay?.canShow == true) {
            diag("still foreground — re-eject HOME (guard)")
            BlockGuardService.goHome(context())
        }
        scheduleNext()
    }

    private fun showOverlay(pkg: String, verdict: PolicySnapshot.BlockVerdict) {
        // Verification-loop refresh: the sheet for this package is
        // normally already up (early-returned); if it was lost, rebuild
        // it with the same countdown semantics.
        val a11y = a11yOverlay
        if (a11y != null && a11y.showOverlay(pkg, verdict) { onGraceEnded(pkg, userInitiated = true) }) return
        val guard = guardOverlay
        if (guard != null && guard.canShow &&
            guard.showOverlay(pkg, verdict) { onGraceEnded(pkg, userInitiated = true) }
        ) return
        BlockGuardService.notifyBlocked(context() ?: return, pkg)
    }

    private fun settle() {
        handler.removeCallbacks(recheckRunnable)
        recheckStep = 0
        laterRechecks = 0
        if (enforcedPkg != null) diag("released (foreground left ${enforcedPkg})")
        enforcedPkg = null
        a11yOverlay?.dismissOverlay()
        guardOverlay?.dismissOverlay()
    }

    private fun scheduleRecheck(step: Int) {
        recheckStep = step
        val delay = if (step < RECHECK_DELAYS.size) RECHECK_DELAYS[step] else RECHECK_LATER_MS
        handler.postDelayed(recheckRunnable, delay)
    }

    private fun scheduleNext() {
        if (recheckStep < RECHECK_DELAYS.size) {
            scheduleRecheck(recheckStep + 1)
            return
        }
        if (++laterRechecks > MAX_LATER_RECHECKS) {
            // Stop ejecting; the overlay stays covering the blocked
            // app and the next real foreground event releases it.
            return
        }
        scheduleRecheck(recheckStep + 1)
    }

    // ------------------------------------------------------------------
    // Shared helpers
    // ------------------------------------------------------------------

    private fun context(): Context? = appContext

    /** Home-screen/system shells are not "opened apps": their time
     *  never counts toward screen time and reaching one releases the
     *  block overlay. */
    fun isShellPackage(pkg: String): Boolean =
        pkg == appContext?.packageName ||
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
}
