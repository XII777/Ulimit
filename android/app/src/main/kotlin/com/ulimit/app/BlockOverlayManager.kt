package com.ulimit.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.animation.AccelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

/**
 * The block pop-layer — an iOS-style bottom sheet instead of the old
 * full-screen takeover:
 *
 *  - adaptive height: the window is WRAP_CONTENT anchored at the
 *    screen bottom, so the sheet is only as tall as its content and
 *    the blocked app stays visible behind it;
 *  - header card: app icon on the left, app name + restriction reason
 *    on the right;
 *  - stats row: the set time limit ("Until 21:30" / "Permanent") and
 *    the remaining time, side by side;
 *  - a bar that depletes with the remaining restriction time;
 *  - below the card, a pill that IS the 10-second counter: a circular
 *    ring depleting around the live seconds, next to "Close" — the
 *    app is NOT ejected instantly anymore; when the ring empties the
 *    engine ejects ([onAction]), the user can tap the pill to close
 *    immediately, or just back out themselves;
 *  - iOS-style motion: spring slide-up + fade in (overshoot), slide-
 *    down + fade out on dismiss.
 *
 * Window type follows the host: TYPE_ACCESSIBILITY_OVERLAY (no extra
 * permission) from the accessibility service, TYPE_APPLICATION_OVERLAY
 * ("Display over other apps") from the guard service.
 */
class BlockOverlayManager(
    private val context: Context,
    private val windowType: Int,
) {

    companion object {
        /** Grace period before the engine ejects the app. The engine
         *  reads this constant — keep it the single source of truth. */
        const val GRACE_MS = 10_000L

        /** Smooth countdown tick. */
        private const val TICK_MS = 100L
    }

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val windowManager: WindowManager
        get() = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private var overlayView: View? = null
    private var overlayPackageName: String? = null

    val currentPackageName: String?
        get() = overlayPackageName

    /** Whether addView can succeed right now: the application-overlay
     *  host needs "Display over other apps"; the accessibility host
     *  always can (while its service lives). */
    val canShow: Boolean
        get() = windowType != WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY ||
            Settings.canDrawOverlays(context)

    val isShowing: Boolean
        get() = overlayView != null

    /** @return `true` if the sheet is now displayed for [packageName].
     *  A repeat call for the same package keeps the running countdown
     *  (never restarts it). */
    fun showOverlay(
        packageName: String,
        verdict: PolicySnapshot.BlockVerdict,
        onAction: (() -> Unit)? = null,
    ): Boolean {
        if (overlayView != null && overlayPackageName == packageName) return true
        dismissOverlay()

        val appName = try {
            val pm = context.packageManager
            val info = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(info)?.toString() ?: packageName
        } catch (_: Exception) {
            packageName
        }

        val appIcon = try {
            context.packageManager.getApplicationIcon(packageName)
        } catch (_: Exception) {
            null
        }

        val density = context.resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()

        fun rounded(color: String, radiusDp: Float, stroke: String? = null): GradientDrawable =
            GradientDrawable().apply {
                setColor(Color.parseColor(color))
                cornerRadius = radiusDp * density
                stroke?.let { setStroke(dp(1), Color.parseColor(it)) }
            }

        // ---------------- card ----------------
        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(18), dp(20), dp(16))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#F51C1C1E"))
                val r = dp(28).toFloat()
                // top-left + top-right rounded; bottom square (sheet).
                cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
            }
        }

        // ---- header: icon left · name + reason right ----
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val iconHolder = android.widget.FrameLayout(context).apply {
            layoutParams = LinearLayout.LayoutParams(dp(46), dp(46))
            background = rounded("#1FFFFFFF", 13f)
            gravity = Gravity.CENTER
        }
        appIcon?.let {
            iconHolder.addView(
                ImageView(context).apply {
                    setImageDrawable(it)
                    layoutParams = android.widget.FrameLayout.LayoutParams(dp(30), dp(30))
                }
            )
        }
        header.addView(iconHolder)

        header.addView(
            LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(
                    0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f
                ).apply { marginStart = dp(12) }
                addView(
                    TextView(context).apply {
                        text = appName
                        setTextColor(Color.parseColor("#F5F5F4"))
                        textSize = 16f
                        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                        maxLines = 1
                        ellipsize = android.text.TextUtils.TruncateAt.END
                    }
                )
                addView(
                    TextView(context).apply {
                        text = verdict.reason
                        setTextColor(Color.parseColor("#A3A3A6"))
                        textSize = 12f
                        maxLines = 1
                        ellipsize = android.text.TextUtils.TruncateAt.END
                    }
                )
            }
        )
        card.addView(header)

        // ---- stats row: set limit · remaining ----
        val indefinite = verdict.untilMillis <= 0L
        val limitValue = if (indefinite) "Permanent" else "Until ${formatClock(verdict.untilMillis)}"

        fun statColumn(label: String, value: String, alignEnd: Boolean) =
            LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(
                    0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f
                )
                gravity = if (alignEnd) Gravity.END else Gravity.START
                addView(
                    TextView(context).apply {
                        text = label
                        setTextColor(Color.parseColor("#6B6B6F"))
                        textSize = 10.5f
                        letterSpacing = 0.08f
                        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    }
                )
                addView(
                    TextView(context).apply {
                        text = value
                        setTextColor(Color.parseColor("#F5F5F4"))
                        textSize = 13.5f
                        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                        setPadding(0, dp(3), 0, 0)
                    }
                )
            }

        val remainingCol = statColumn("TIME LIMIT", limitValue, alignEnd = false)
        val countdownCol = statColumn("REMAINING", "—", alignEnd = true)
        card.addView(
            LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, dp(16), 0, 0)
                addView(remainingCol)
                addView(countdownCol)
            }
        )

        // ---- remaining-time bar ----
        val bar = ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(6)
            ).apply { topMargin = dp(12) }
            max = 10_000
            progressTintList = android.content.res.ColorStateList.valueOf(Color.parseColor("#F0F0F0"))
            progressBackgroundTintList =
                android.content.res.ColorStateList.valueOf(Color.parseColor("#3A3A3E"))
        }
        card.addView(bar)

        // ---- the 10s counter pill: ring countdown · Close ----
        val ring = CountdownRing(context).apply {
            layoutParams = LinearLayout.LayoutParams(dp(38), dp(38))
        }
        val closeLabel = TextView(context).apply {
            text = "Close"
            setTextColor(Color.parseColor("#F5F5F4"))
            textSize = 13.5f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { marginStart = dp(10) }
        }
        val pill = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded("#14FFFFFF", 27f, stroke = "#3A3A3E")
            setPadding(dp(10), dp(7), dp(20), dp(7))
            isClickable = true
            isFocusable = false
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                topMargin = dp(14)
            }
            setOnClickListener { onAction?.invoke() }
            addView(ring)
            addView(closeLabel)
        }
        card.addView(pill)

        // ---------------- window ----------------
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.BOTTOM
        }

        var shown = false
        try {
            windowManager.addView(card, params)
            overlayView = card
            overlayPackageName = packageName
            shown = true
        } catch (_: Exception) {
            return false
        }

        // iOS-style entrance: spring slide-up + fade.
        card.alpha = 0f
        card.translationY = dp(90)
        card.post {
            try {
                card.animate()
                    .translationY(0f)
                    .alpha(1f)
                    .setDuration(420)
                    .setInterpolator(OvershootInterpolator(1.12f))
                    .start()
            } catch (_: Exception) {
            }
        }

        // ---------------- countdown + bar tick ----------------
        val startAt = System.currentTimeMillis()
        val total = if (indefinite) 1L else (verdict.untilMillis - startAt).coerceAtLeast(1L)
        var actionFired = false

        val tick = object : Runnable {
            override fun run() {
                if (overlayView !== card) return
                val now = System.currentTimeMillis()

                // 10s counter pill: ring depletes, seconds tick inside.
                val graceLeft = (GRACE_MS - (now - startAt)).coerceAtLeast(0)
                ring.progress = graceLeft / GRACE_MS.toFloat()
                ring.secondsLeft = ((graceLeft + 999) / 1000).toInt()

                // Restriction remaining time + bar.
                if (indefinite) {
                    (countdownCol.getChildAt(1) as TextView).text = "Until removed"
                    bar.progress = 10_000
                } else {
                    val remaining = (total - (now - startAt)).coerceAtLeast(0)
                    (countdownCol.getChildAt(1) as TextView).text = formatRemainingTime(remaining)
                    bar.progress = ((remaining * 10_000) / total).toInt()
                }

                if (graceLeft <= 0L) {
                    if (!actionFired) {
                        actionFired = true
                        onAction?.invoke()
                    }
                    return
                }
                handler.postDelayed(this, TICK_MS)
            }
        }
        handler.postDelayed(tick, TICK_MS)
        return shown
    }

    /** Slide-down + fade out, then remove — iOS-style dismissal. */
    fun dismissOverlay() {
        handler.removeCallbacksAndMessages(null)
        val view = overlayView ?: run {
            overlayPackageName = null
            return
        }
        overlayView = null
        overlayPackageName = null
        try {
            view.animate().cancel()
            view.animate()
                .translationY((view.height.coerceAtLeast(1)) * 0.4f)
                .alpha(0f)
                .setDuration(260)
                .setInterpolator(AccelerateInterpolator())
                .withEndAction {
                    try {
                        windowManager.removeView(view)
                    } catch (_: Exception) {
                    }
                }
                .start()
        } catch (_: Exception) {
            try {
                windowManager.removeView(view)
            } catch (_: Exception) {
            }
        }
    }

    /** A small top-of-screen badge (non-blocking — the browser still
     *  shows behind it while the back happens). Auto-hides in 4s. */
    fun showSmallNotice(packageName: String, message: String) {
        dismissOverlay()
        try {
            val density = context.resources.displayMetrics.density
            fun dp(v: Int): Int = (v * density).toInt()

            val view = TextView(context).apply {
                text = "Blocked by Ulimit · $message"
                setTextColor(android.graphics.Color.parseColor("#F5F5F4"))
                setBackgroundColor(android.graphics.Color.parseColor("#CC0A0A0B"))
                textSize = 12f
                gravity = Gravity.CENTER
                setPadding(dp(20), dp(8), dp(20), dp(8))
            }

            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                dp(34),
                windowType,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP
                y = dp(40)
            }

            windowManager.addView(view, params)
            overlayView = view
            overlayPackageName = packageName
            handler.postDelayed({ dismissOverlay() }, 4000)
        } catch (_: Exception) {
        }
    }

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

    private fun formatClock(epochMillis: Long): String =
        java.lang.String.format("%tR", java.util.Date(epochMillis))

    /**
     * The circular 10s counter inside the pill: a track ring with a
     * depleting progress arc (starts at 12 o'clock) and the live
     * seconds centered inside.
     */
    private class CountdownRing(context: Context) : View(context) {

        private val density = context.resources.displayMetrics.density

        private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            color = Color.parseColor("#3A3A3E")
            strokeWidth = 2.5f * density
        }
        private val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            color = Color.parseColor("#F5F5F4")
            strokeWidth = 2.5f * density
        }
        private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#F5F5F4")
            textSize = 11f * density
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textAlign = Paint.Align.CENTER
        }

        /** Remaining fraction 1 → 0. */
        var progress = 1f
            set(value) {
                field = value.coerceIn(0f, 1f)
                invalidate()
            }

        var secondsLeft = 10
            set(value) {
                field = value
                invalidate()
            }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val cx = width / 2f
            val cy = height / 2f
            val r = (minOf(width, height) - track.strokeWidth) / 2f
            val rect = RectF(cx - r, cy - r, cx + r, cy + r)
            canvas.drawArc(rect, 0f, 360f, false, track)
            canvas.drawArc(rect, -90f, 360f * progress, false, arc)
            val textY = cy - (label.ascent() + label.descent()) / 2f
            canvas.drawText("${secondsLeft}s", cx, textY, label)
        }
    }
}
