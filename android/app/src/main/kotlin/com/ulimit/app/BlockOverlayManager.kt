package com.ulimit.app

import android.content.Context
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.animation.AccelerateInterpolator
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

/**
 * The block screen — a FULL-SCREEN, fully opaque takeover:
 *
 *  - the window is MATCH_PARENT × MATCH_PARENT with an opaque
 *    background and no translucency — the blocked app is completely
 *    hidden and cannot receive touches through the layer;
 *  - top half: the app's icon, name, restriction reason, its time used
 *    TODAY, and a random focus quote filling the space;
 *  - bottom block: the set time limit ("Until 21:30" / "Permanent")
 *    and the remaining time, a bar that depletes with the remaining
 *    restriction time, and a full-width Close button — the app is NOT
 *    ejected instantly; the user either taps Close ([onAction], which
 *    ejects) or backs out themselves;
 *  - motion: soft fade-in / fade-out.
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
        /** Refresh cadence for the REMAINING stat + bar. */
        private const val TICK_MS = 1000L
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

        fun centerIcon(holder: android.widget.FrameLayout, icon: android.graphics.drawable.Drawable?, sizeDp: Int) {
            icon?.let {
                holder.addView(
                    ImageView(context).apply {
                        setImageDrawable(it)
                        layoutParams = android.widget.FrameLayout.LayoutParams(
                            dp(sizeDp), dp(sizeDp), Gravity.CENTER
                        )
                    }
                )
            }
        }

        // ---------------- full-screen root ----------------
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            // Fully opaque — the blocked app must not show through.
            setBackgroundColor(Color.parseColor("#0A0A0B"))
            setPadding(dp(24), dp(28), dp(24), dp(24))
        }

        // ---- top: icon, name, reason ----
        val iconHolder = android.widget.FrameLayout(context).apply {
            layoutParams = LinearLayout.LayoutParams(dp(64), dp(64)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
            }
            background = rounded("#1FFFFFFF", 18f)
        }
        centerIcon(iconHolder, appIcon, 42)
        root.addView(iconHolder)

        root.addView(
            TextView(context).apply {
                text = appName
                setTextColor(Color.parseColor("#F5F5F4"))
                textSize = 20f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                gravity = Gravity.CENTER
                setPadding(0, dp(14), 0, 0)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            }
        )
        root.addView(
            TextView(context).apply {
                text = verdict.reason
                setTextColor(Color.parseColor("#A3A3A6"))
                textSize = 13f
                gravity = Gravity.CENTER
                setPadding(0, dp(3), 0, 0)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            }
        )

        // ---- today's use of this app (from the native usage
        //      accumulator — the same numbers the engine enforces) ----
        val usedSeconds = PolicySnapshot.usageSeconds(context)[packageName] ?: 0
        root.addView(
            TextView(context).apply {
                text = "Used today · ${formatUsedTime(usedSeconds * 1000L)}"
                setTextColor(Color.parseColor("#F5F5F4"))
                textSize = 14f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                gravity = Gravity.CENTER
                setPadding(0, dp(10), 0, 0)
            }
        )

        // ---- spacer: the motivational quote fills the empty space
        //      between the header block and the countdown block ----
        root.addView(
            TextView(context).apply {
                text = FocusQuotes.random()
                setTextColor(Color.parseColor("#8E8E93"))
                textSize = 15f
                typeface = Typeface.create(Typeface.DEFAULT_BOLD, Typeface.ITALIC)
                setLineSpacing(dp(3).toFloat(), 1f)
                setPadding(dp(16), 0, dp(16), 0)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f
                ).apply { topMargin = dp(24); bottomMargin = dp(24) }
                // Center the quote inside its flexible area.
                gravity = Gravity.CENTER
            }
        )

        // ---- bottom block: limit · remaining + bar + close pill ----
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
        root.addView(
            LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
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
        root.addView(bar)

        // ---- full-width Close button: ejects the blocked app ----
        val closeButton = TextView(context).apply {
            text = "Close"
            setTextColor(Color.parseColor("#F5F5F4"))
            textSize = 15f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            gravity = Gravity.CENTER
            background = rounded("#14FFFFFF", 16f, stroke = "#3A3A3E")
            setPadding(0, dp(15), 0, dp(15))
            isClickable = true
            isFocusable = false
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(18) }
            setOnClickListener { onAction?.invoke() }
        }
        root.addView(closeButton)

        // ---------------- window ----------------
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            // Opaque: no layer transparency — the blocked app must not
            // be visible or touchable behind this screen.
            PixelFormat.OPAQUE
        )

        var shown = false
        try {
            windowManager.addView(root, params)
            overlayView = root
            overlayPackageName = packageName
            shown = true
        } catch (_: Exception) {
            return false
        }

        // Soft fade-in.
        root.alpha = 0f
        root.post {
            try {
                root.animate()
                    .alpha(1f)
                    .setDuration(260)
                    .start()
            } catch (_: Exception) {
            }
        }

        // ---------------- countdown + bar tick ----------------
        val startAt = System.currentTimeMillis()
        val total = if (indefinite) 1L else (verdict.untilMillis - startAt).coerceAtLeast(1L)

        // Keeps the REMAINING stat + bar fresh. Ejection happens only
        // when the user taps Close (or backs out) — there is no auto
        // countdown anymore.
        val tick = object : Runnable {
            override fun run() {
                if (overlayView !== root) return
                val now = System.currentTimeMillis()

                if (indefinite) {
                    (countdownCol.getChildAt(1) as TextView).text = "Until removed"
                    bar.progress = 10_000
                } else {
                    val remaining = (total - (now - startAt)).coerceAtLeast(0)
                    (countdownCol.getChildAt(1) as TextView).text = formatRemainingTime(remaining)
                    bar.progress = ((remaining * 10_000) / total).toInt()
                }

                handler.postDelayed(this, TICK_MS)
            }
        }
        handler.postDelayed(tick, TICK_MS)
        return shown
    }

    /** Fade out, then remove — the full screen leaves softly. */
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
                .alpha(0f)
                .setDuration(220)
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

    private fun formatUsedTime(millis: Long): String {
        val totalMin = (millis / 60000).coerceAtLeast(0L)
        val h = totalMin / 60
        val m = totalMin % 60
        return when {
            h > 0 -> "${h}h ${m}m"
            m > 0 -> "${m}m"
            else -> "under a minute"
        }
    }

    private fun formatClock(epochMillis: Long): String =
        java.lang.String.format("%tR", java.util.Date(epochMillis))
}

/** Motivational quotes shown on the block screen — one is picked at
 *  random per blocking so the empty space carries a different nudge
 *  every time. Focus/attention themed, no attribution clutter. */
object FocusQuotes {
    private val quotes = listOf(
        "Attention is the rarest and purest form of generosity.",
        "The successful warrior is the average person with laser-like focus.",
        "Where focus goes, energy flows.",
        "You will never reach your destination if you stop and throw stones at every dog that barks.",
        "Depth beats breadth every single day.",
        "Your attention is your currency. Spend it deliberately.",
        "The difference between ordinary and extraordinary is the word extra — the extra focus.",
        "Distraction is the enemy of creation.",
        "Do fewer things, better.",
        "Almost everything will work again if you unplug it for a few minutes — including you.",
        "Discipline is choosing between what you want now and what you want most.",
        "One screen at a time. One task at a time. One life at a time.",
        "The future depends on what you do today — not what you scroll today.",
        "Focus is saying no to a thousand good things.",
        "Five focused minutes beat an hour of half-attention.",
        "Protect your mornings. Guard your focus. Own your day.",
        "The scroll ends here. The rest of your day begins now.",
        "You didn't come this far to only come this far.",
    )

    fun random(): String = quotes.random()
}
