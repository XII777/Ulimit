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

    /** Duplicate enforce calls for the same package inside this window
     *  are collapsed — the recheck loop owns persistence. */
    private const val ENFORCE_DEDUPE_MS = 1200L

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
    private var lastEnforceAt = 0L
    private var recheckStep = 0
    private var laterRechecks = 0
    private val recheckRunnable = Runnable { recheck() }

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
        appContext?.let {
            if (PolicySnapshot.isDebugBuild(it)) {
                Log.d(TAG, "engine: accessibility actuator attached")
            }
        }
    }

    fun detachAccessibility(ejector: Ejector) {
        if (this.ejector === ejector) {
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
        if (PolicySnapshot.isDebugBuild(context)) {
            Log.d(TAG, "evaluate($pkg): ${verdict?.reason ?: "allowed"}")
        }
        if (verdict != null) enforce(pkg, verdict) else settle()
    }

    private fun enforce(pkg: String, verdict: PolicySnapshot.BlockVerdict) {
        val now = System.currentTimeMillis()
        if (pkg == enforcedPkg && now - lastEnforceAt < ENFORCE_DEDUPE_MS) return

        enforcedPkg = pkg
        lastEnforceAt = now
        recheckStep = 0
        laterRechecks = 0

        showOverlay(pkg, verdict)

        // 1) First eject: BACK finishes most apps instantly.
        ejector?.pressBack()

        // 2) Relentless verification: while this package is still
        //    foreground we re-eject with HOME on every tick. The
        //    overlay is NOT on a timer — it lives until the foreground
        //    genuinely moves off the blocked app.
        scheduleRecheck(0)
    }

    private fun recheck() {
        val pkg = enforcedPkg ?: return
        val context = appContext ?: return

        val fg = ejector?.activeWindowPackage() ?: trackedForeground()
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

        // Keep the pop-layer honest and in place…
        showOverlay(pkg, verdict)
        // …then eject harder. BACK was already tried; HOME closes even
        // apps that swallow BACK. Repeated HOME presses are idempotent.
        ejector?.pressHome()
        scheduleNext()
    }

    private fun showOverlay(pkg: String, verdict: PolicySnapshot.BlockVerdict) {
        val a11y = a11yOverlay
        if (a11y != null) {
            a11y.showOverlay(pkg, verdict)
            return
        }
        val guard = guardOverlay
        if (guard != null && guard.canShow) {
            guard.showOverlay(pkg, verdict)
            return
        }
        // No overlay host can draw: surface a heads-up notification so
        // the user still gets an active signal, not silence.
        BlockGuardService.notifyBlocked(context() ?: return, pkg)
    }

    private fun settle() {
        handler.removeCallbacks(recheckRunnable)
        recheckStep = 0
        laterRechecks = 0
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
