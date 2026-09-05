package com.ulimit.app

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.max

/**
 * The ONE native rolling-number implementation — the same motion the
 * Flutter NumberFlow (DurationFlow) uses on in-app screens, applied to
 * the system surfaces: the floating [FocusSessionPill] and the
 * [FocusSessionPopupActivity] panel. Every native countdown digit
 * change goes through [roll]; no other rolling animation may exist.
 */
object RollingDigits {

    /** Damped-spring overshoot (matches the app's iOS-feel springs). */
    private class Spring(private val stiffness: Double = 1200.0,
                         private val damping: Double = 0.72) : android.view.animation.Interpolator {
        override fun getInterpolation(input: Float): Float {
            val t = input.toDouble().coerceIn(0.0, 1.0)
            val zeta = damping.coerceAtMost(0.995)
            val omegaN = Math.sqrt(stiffness)
            val omegaD = omegaN * Math.sqrt(1.0 - zeta * zeta)
            val decay = Math.exp(-zeta * omegaN * t)
            val phase = omegaD * t
            return (1.0 - decay * (Math.cos(phase) + (zeta * omegaN / omegaD) * Math.sin(phase)))
                .toFloat()
        }
    }

    /**
     * Lift the old value out faded, snap the new value in from under it
     * and spring it up — descending odometer roll, one per change.
     * No-op when the text already matches (keeps quiet frames cheap).
     */
    @SuppressLint("WrongThread")
    fun roll(view: TextView, next: String, density: Float) {
        if (view.text == next) return
        view.animate().cancel()
        view.animate()
            .alpha(0f)
            .translationY(-16f * density)
            .setDuration(110)
            .withEndAction {
                view.text = next
                view.alpha = 0f
                view.translationY = 16f * density
                view.animate()
                    .alpha(1f)
                    .translationY(0f)
                    .setDuration(200)
                    .setInterpolator(Spring())
                    .start()
            }
            .start()
    }
}

/**
 * Ulimit's OWN floating Focus Session pill — a small capsule overlay
 * (deliberately NOT the system call-style chip: no call category, no
 * avatar, no hang-up affordance) that hovers under the status bar for
 * the whole session and shows a live rolling remaining time in the
 * app's monochrome design language:
 *
 *     ● FOCUS · 24:38
 *
 * Surface, stroke and text colors mirror lib/core/theme/tokens.dart
 * (night + light palettes) — light/dark resolution follows the system
 * UI mode, the same source the app's theme uses.
 *
 * The remaining time is computed ONLY from the session's real
 * timestamps (remaining = endMillis − now, frozen while paused) — the
 * roll animation never drives the value, so the pill stays accurate
 * across backgrounding, lock, UI recreation and lifecycle changes.
 *
 * Tapping it opens the existing fly-out control panel (remaining time,
 * Pause/Resume, End, Open Ulimit) — the SAME session source of truth.
 * Requires the one-time "Display over other apps" permission; without
 * it the pill is simply not shown (the ongoing notification still
 * covers controls).
 */
class FocusSessionPill(private val context: Context) {

    companion object {
        fun canShow(context: Context): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && Settings.canDrawOverlays(context)
    }

    private val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val density = context.resources.displayMetrics.density
    private val handler = Handler(Looper.getMainLooper())

    private var root: LinearLayout? = null
    private var timeView: TextView? = null
    private var startedAt = 0L
    private var endAt = 0L
    private var paused = false
    private var frozenRemaining = 0L

    private val night = (context.resources.configuration.uiMode and
        android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
        android.content.res.Configuration.UI_MODE_NIGHT_YES

    private val ticker = object : Runnable {
        override fun run() {
            render()
            handler.postDelayed(this, 1000L)
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    fun show(startedAtMillis: Long, endMillis: Long, paused: Boolean) {
        this.startedAt = startedAtMillis
        this.endAt = endMillis
        this.paused = paused
        if (root != null) {
            render()
            return
        }
        if (!canShow(context)) return

        val surface = if (night) Color.parseColor("#111111") else Color.parseColor("#F5F5F5")
        val stroke = if (night) Color.parseColor("#222222") else Color.parseColor("#E5E5E5")
        val ink = if (night) Color.parseColor("#FFFFFF") else Color.parseColor("#000000")
        val inkDim = if (night) Color.parseColor("#AFAFAF") else Color.parseColor("#666666")

        val capsule = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(13), dp(8), dp(15), dp(8))
            background = GradientDrawable().apply {
                setColor(surface)
                cornerRadius = dp(999).toFloat()
                setStroke(max(1, dp(1)), stroke)
            }
            isClickable = true
            setOnClickListener { openPanel() }
        }

        // The living "focus" pulse-dot — the app's accent state cue.
        capsule.addView(View(context).apply {
            val d = dp(7)
            layoutParams = LinearLayout.LayoutParams(d, d)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(ink)
            }
        })

        capsule.addView(
            TextView(context).apply {
                text = "FOCUS"
                setTextColor(inkDim)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
                setTypeface(Typeface.create(Typeface.DEFAULT, Typeface.BOLD))
                letterSpacing = 0.1f
                setPadding(dp(8), 0, 0, 0)
            },
        )

        timeView = TextView(context).apply {
            setTextColor(ink)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
            setTypeface(Typeface.create(Typeface.DEFAULT, Typeface.BOLD))
            val tf = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            typeface = tf
            setPadding(dp(6), 0, 0, 0)
        }
        capsule.addView(timeView)

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = dp(6) + statusBarHeight()
        }

        try {
            wm.addView(capsule, params)
            root = capsule
            render()
            handler.postDelayed(ticker, 1000L)
        } catch (_: Exception) {
            root = null
        }
    }

    /** Same arguments on every session change (pause, resume, doom
     * counts don't matter here — timestamps drive). */
    fun update(startedAtMillis: Long, endMillis: Long, paused: Boolean) {
        show(startedAtMillis, endMillis, paused)
    }

    fun hide() {
        handler.removeCallbacks(ticker)
        root?.let {
            try {
                wm.removeView(it)
            } catch (_: Exception) {
            }
        }
        root = null
        timeView = null
    }

    /** Remaining = real session timestamps; frozen while paused. */
    private fun currentRemainingMs(): Long {
        if (endAt <= 0L) return 0L
        return if (paused) {
            frozenRemaining
        } else {
            (endAt - System.currentTimeMillis()).coerceAtLeast(0L).also { frozenRemaining = it }
        }
    }

    private fun render() {
        if (!paused) frozenRemaining = (endAt - System.currentTimeMillis()).coerceAtLeast(0L)
        val tv = timeView ?: return
        val secs = currentRemainingMs() / 1000L
        val h = secs / 3600
        val m = (secs % 3600) / 60
        val s = secs % 60
        val text = if (h > 0) {
            "%d:%02d:%02d".format(h, m, s)
        } else {
            "%02d:%02d".format(m, s)
        }
        RollingDigits.roll(tv, text, density)
    }

    private fun openPanel() {
        try {
            context.startActivity(
                Intent(context, FocusSessionPopupActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    putExtra(FocusSessionPopupActivity.EXTRA_LABEL, "Focus")
                    putExtra(FocusSessionPopupActivity.EXTRA_PAUSED, paused)
                    putExtra(FocusSessionPopupActivity.EXTRA_END, endAt)
                    putExtra(FocusSessionPopupActivity.EXTRA_STARTED_AT, startedAt)
                },
            )
        } catch (_: Exception) {
        }
    }

    private fun statusBarHeight(): Int {
        val id = context.resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) context.resources.getDimensionPixelSize(id) else dp(24)
    }

    private fun dp(v: Int) = (v * density).toInt()
}
