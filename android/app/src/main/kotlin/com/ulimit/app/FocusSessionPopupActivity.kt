package com.ulimit.app

import android.animation.TimeInterpolator
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.max

/**
 * Damped-spring [TimeInterpolator] (no androidx dependency): maps a
 * 0..1 progress to an over/undershoot curve so the popup visibly
 * springs into place instead of easing. [dampingRatio] is the
 * oscillator's zeta — ~0.72 gives one clean overshoot and a quick
 * settle (iOS-sheet feel), zero jitter.
 */
class SpringBounceInterpolator(
    private val stiffness: Float = 96f,
    private val dampingRatio: Float = 0.72f,
) : TimeInterpolator {
    override fun getInterpolation(input: Float): Float {
        val omegaN = Math.sqrt(stiffness.toDouble() * 12.0)
        val zeta = dampingRatio.toDouble().coerceAtMost(0.995)
        val t = input.toDouble().coerceIn(0.0, 1.0)
        val omegaD = omegaN * Math.sqrt(1.0 - zeta * zeta)
        val decay = Math.exp(-zeta * omegaN * t)
        val phase = omegaD * t
        val value = 1.0 - decay * (Math.cos(phase) + (zeta * omegaN / omegaD) * Math.sin(phase))
        return value.toFloat()
    }
}

/**
 * The notification / status-bar-pill tap target — an app-themed sheet
 * that springs out of the chip, in the app's monochrome dark palette
 * (literals mirror lib/core/theme/tokens.dart):
 *
 *  - focus-ring badge + session label + Running/Paused status;
 *  - the LIVE remaining time ROLLING like Flutter's NumberFlow — the
 *    old value lifts out faded, the new springs up from below — and
 *    clamped at 00:00, never a negative;
 *  - session progress line (fills left→right), like the in-app ring;
 *  - redesigned pill buttons: Pause/Resume (ink pill), End (ghost
 *    pill) — routed through [FocusSessionActionReceiver], the SAME
 *    source of truth as the notification buttons;
 *  - "Open Ulimit  →" launches the app ON THE FOCUS SCREEN itself
 *    (warm engine re-navigates via MainActivity's navigation extras).
 *
 * A tap on the scrim outside springs the sheet back out.
 */
class FocusSessionPopupActivity : Activity() {

    companion object {
        const val EXTRA_LABEL = "label"
        const val EXTRA_PAUSED = "paused"
        const val EXTRA_END = "endMillis"
        const val EXTRA_STARTED_AT = "startedAtMillis"
        const val EXTRA_DOOM_PACKAGE = "doomPackage"
        const val EXTRA_DOOM_COUNT = "doomCount"
    }

    private val tick = Handler(Looper.getMainLooper())
    private val openedAt = System.currentTimeMillis()

    private var startedAt = 0L
    private var endAt = 0L
    private var paused = false
    private var lastShownTime = ""

    private lateinit var card: LinearLayout
    private lateinit var timeText: TextView
    private lateinit var statusText: TextView
    private lateinit var toggleBtn: TextView
    private lateinit var progressTrack: View
    private lateinit var progressFill: View

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Fly-out sheet: the window stays fully transparent except the
        // card itself — no dim, no full-screen surface. Tap outside =
        // dismiss (the scrim's click handler), the card swallows its
        // own taps.
        window.requestFeature(Window.FEATURE_NO_TITLE)
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        window.setLayout(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
        )
        window.setDimAmount(0f)

        val label = intent.getStringExtra(EXTRA_LABEL) ?: "Focus"
        paused = intent.getBooleanExtra(EXTRA_PAUSED, false)
        startedAt = intent.getLongExtra(EXTRA_STARTED_AT, openedAt)
        endAt = intent.getLongExtra(EXTRA_END, 0L)
        val doomPkg = intent.getStringExtra(EXTRA_DOOM_PACKAGE)
        val doomCount = intent.getIntExtra(EXTRA_DOOM_COUNT, 0)

        val scrim = FrameLayout(this).apply {
            setBackgroundColor(0x01000000) // hit-sink only, no visual
            setOnClickListener { springOutAndFinish() }
        }

        card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(0xFF141414.toInt()) // card surface
                // All corners rounded + light elevation: a floating
                // fly-out card, not an edge-attached sheet.
                cornerRadius = dpF(26f)
                setStroke(max(1, dpF(1.2f).toInt()), 0xFF26262A.toInt())
            }
            elevation = dpF(18f)
            setPadding(dp(22), dp(20), dp(22), dp(20))
            isClickable = true // card taps must not reach the scrim
        }
        scrim.addView(
            card,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                // Top-end: right under the status-bar icon the user
                // tapped — a fly-out, with side margin.
                Gravity.TOP or Gravity.END,
            ).apply {
                setMargins(dp(120), dp(44), dp(16), dp(16))
            },
        )

        buildHeader(label)
        doomPkg?.takeIf { doomCount > 0 }?.let { buildDoomLine(it, doomCount) }
        buildCountdown()
        buildProgressLine()
        buildButtons()
        buildOpenLink()

        setContentView(scrim)

        // Spring entrance out of the chip.
        card.translationY = -dpF(90f)
        card.alpha = 0f
        card.animate()
            .translationY(0f)
            .alpha(1f)
            .setDuration(440)
            .setInterpolator(SpringBounceInterpolator())
            .start()

        tick.postDelayed(ticker, 250)
    }

    // ------------------------------------------------------------------
    // pieces
    // ------------------------------------------------------------------

    private fun buildHeader(label: String) {
        val header = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        header.gravity = Gravity.CENTER_VERTICAL

        val badge = ImageView(this).apply {
            setImageResource(R.drawable.ic_stat_focus)
            setColorFilter(0xFF77777C.toInt())
            background = GradientDrawable().apply {
                setColor(0xFF1D1D21.toInt())
                val r = dpF(14f)
                cornerRadii = floatArrayOf(r, r, r, r, r, r, r, r)
                setStroke(max(1, dpF(1f).toInt()), 0xFF26262A.toInt())
            }
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(7), dp(7), dp(7), dp(7))
        }
        header.addView(badge, LinearLayout.LayoutParams(dp(36), dp(36)))

        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(
            textView(label, 16f, 0xFFF5F5F4.toInt(), bold = true),
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        statusText = textView(
            if (paused) "Paused" else "Session running",
            11.5f,
            0xFF6E6E73.toInt(),
        )
        col.addView(
            statusText,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        header.addView(
            col,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                marginStart = dp(12)
                marginEnd = dp(8)
            },
        )

        card.addView(
            header,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
    }

    private fun buildDoomLine(doomPkg: String, doomCount: Int) {
        val appName = try {
            packageManager.getApplicationLabel(
                packageManager.getApplicationInfo(doomPkg, 0),
            ).toString()
        } catch (_: Exception) {
            doomPkg
        }
        card.addView(
            textView(
                "$doomCount scrolls today · $appName",
                11f,
                0xFF5C5C62.toInt(),
            ).apply { setPadding(0, dp(10), 0, 0) },
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
    }

    private fun buildCountdown() {
        lastShownTime = remainingText()
        timeText = textView(lastShownTime, 46f, 0xFFF5F5F4.toInt(), bold = true).apply {
            letterSpacing = 0.06f
            setTypeface(Typeface.create("sans-serif", Typeface.BOLD))
            setPadding(0, dp(18), 0, 0)
        }
        card.addView(
            timeText,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
    }

    private fun buildProgressLine() {
        val frame = FrameLayout(this)
        progressTrack = View(this).apply {
            background = GradientDrawable().apply {
                setColor(0xFF242428.toInt())
                cornerRadius = dpF(1.5f)
            }
        }
        frame.addView(progressTrack, frameLp(FrameLayout.LayoutParams.MATCH_PARENT, dp(3)))
        progressFill = View(this).apply {
            background = GradientDrawable().apply {
                setColor(0xFFF5F5F4.toInt())
                cornerRadius = dpF(1.5f)
            }
        }
        frame.addView(progressFill, frameLp(0, dp(3)))
        card.addView(
            frame,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(12) },
        )
    }

    private fun buildButtons() {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }

        toggleBtn = pill(if (paused) "Resume" else "Pause", filled = true) {
            sendAction(
                if (paused) FocusSessionActionReceiver.ACTION_RESUME
                else FocusSessionActionReceiver.ACTION_PAUSE,
            )
            // Flip the panel in place instantly; Dart re-pushes the
            // truth a moment later and the pill reflects it.
            paused = !paused
            statusText.text = if (paused) "Paused" else "Session running"
            toggleBtn.text = if (paused) "Resume" else "Pause"
        }
        row.addView(
            toggleBtn,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(46))
                .apply { marginEnd = dp(8) },
        )

        val end = pill("End", filled = false) {
            sendAction(FocusSessionActionReceiver.ACTION_END)
            finish()
        }
        row.addView(
            end,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(46))
                .apply { marginStart = dp(8) },
        )

        card.addView(
            row,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(20) },
        )
    }

    private fun buildOpenLink() {
        card.addView(
            textView("Open Ulimit  →", 12f, 0xFF6E6E73.toInt()).apply {
                gravity = Gravity.CENTER
                setOnClickListener { openSessionScreen() }
                setPadding(0, dp(14), 0, dp(4))
            },
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
    }

    // ------------------------------------------------------------------
    // the live ticking
    // ------------------------------------------------------------------

    private val ticker = object : Runnable {
        override fun run() {
            updateLive()
            tick.postDelayed(this, 1000)
        }
    }

    private fun updateLive() {
        val next = remainingText()
        if (next != lastShownTime) rollTo(next)
        val total = endAt - startedAt
        if (total > 0 && progressTrack.width > 0) {
            val elapsed = (System.currentTimeMillis() - startedAt)
                .coerceIn(0L, total)
                .toFloat()
            val lp = progressFill.layoutParams as FrameLayout.LayoutParams
            lp.width = (progressTrack.width * elapsed / total.toFloat()).toInt()
            progressFill.layoutParams = lp
        }
    }

    /** NumberFlow descending roll — the SAME shared implementation the
     *  floating pill uses (RollingDigits), never a second system. */
    private fun rollTo(next: String) {
        lastShownTime = next
        RollingDigits.roll(timeText, next, resources.displayMetrics.density)
    }

    /** Remaining time: live while running, FROZEN at the moment the
     *  panel opened while paused — and clamped at zero, so a negative
     *  is structurally impossible. */
    private fun remainingText(): String {
        if (endAt <= 0L) return "00:00"
        val from = if (paused) openedAt else System.currentTimeMillis()
        val secs = maxOf(0L, (endAt - from) / 1000L)
        val h = secs / 3600
        val m = (secs % 3600) / 60
        val s = secs % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
    }

    // ------------------------------------------------------------------
    // actions
    // ------------------------------------------------------------------

    private fun sendAction(action: String) {
        sendBroadcast(
            Intent(this, FocusSessionActionReceiver::class.java).apply {
                this.action = action
            },
        )
    }

    /** Launch (or reuse) the app engine and land ON THE FOCUS SCREEN —
     *  [MainActivity] forwards the route to GoRouter over its
     *  navigation channel, and cold-starts with it as initial route. */
    private fun openSessionScreen() {
        startActivity(
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(MainActivity.EXTRA_ROUTE, MainActivity.ROUTE_FOCUS)
            },
        )
        finish()
    }

    private fun springOutAndFinish() {
        tick.removeCallbacksAndMessages(null)
        card.animate()
            .translationY(-dpF(70f))
            .alpha(0f)
            .setDuration(180)
            .setInterpolator(android.view.animation.DecelerateInterpolator())
            .withEndAction { finish() }
            .start()
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        springOutAndFinish()
    }

    override fun onDestroy() {
        tick.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // builders
    // ------------------------------------------------------------------

    private fun textView(
        value: String,
        sizeSp: Float,
        color: Int,
        bold: Boolean = false,
    ): TextView = TextView(this).apply {
        text = value
        setTextColor(color)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun pill(label: String, filled: Boolean, onTap: () -> Unit): TextView =
        TextView(this).apply {
            text = label
            gravity = Gravity.CENTER
            minWidth = dp(124)
            setPadding(dp(22), 0, dp(22), 0)
            setTextColor(if (filled) 0xFF0D0D0F.toInt() else 0xFFF5F5F4.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f)
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable().apply {
                setColor(if (filled) 0xFFF5F5F4.toInt() else 0xFF191A1D.toInt())
                cornerRadius = dpF(24f)
                if (!filled) setStroke(max(1, dpF(1f).toInt()), 0xFF2E2E33.toInt())
            }
            setOnClickListener { onTap() }
        }

    private fun frameLp(w: Int, h: Int) =
        FrameLayout.LayoutParams(w, h, Gravity.START)

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun dpF(v: Float) = v * resources.displayMetrics.density
}
