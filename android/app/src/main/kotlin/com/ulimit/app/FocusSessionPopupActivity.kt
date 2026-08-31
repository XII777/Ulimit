package com.ulimit.app

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.Window
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.animation.SpringInterpolator
import android.widget.LinearLayout.LayoutParams

/**
 * The chip tap target. On API 31+ the ongoing call-style chip opens this
 * translucent activity — a compact panel that springs down from the top
 * of the screen (the same gesture the system uses when you tap a call
 * chip) and offers the session controls:
 *
 *   Pause / Resume (single button, flips with state)
 *   End session
 *
 * All actions route through [FocusSessionActionReceiver] — the same
 * single source of truth the notification buttons use — and the panel
 * dismisses itself immediately after the tap. No engine is spawned
 * here: the receiver owns the Dart bridge.
 */
class FocusSessionPopupActivity : Activity() {

    companion object {
        const val EXTRA_LABEL = "label"
        const val EXTRA_PAUSED = "paused"
    }

    private lateinit var root: LinearLayout
    private lateinit var toggleAction: () -> Unit

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Translucent window over the existing task: the popup feels like
        // it dropped out of the status-bar chip, not a new screen.
        window.requestFeature(Window.FEATURE_NO_TITLE)
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        window.setLayout(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT
        )
        window.setGravity(Gravity.TOP)
        window.setDimAmount(0.25f)

        val label = intent.getStringExtra(EXTRA_LABEL) ?: "Focus"
        val paused = intent.getBooleanExtra(EXTRA_PAUSED, false)

        // The toggle flips: running → paused (send PAUSE), paused →
        // running (send RESUME). Same receiver the pixels of the
        // notification use, so the popup and the chip can never drift.
        toggleAction = {
            if (paused) {
                sendAction(FocusSessionActionReceiver.ACTION_RESUME)
            } else {
                sendAction(FocusSessionActionReceiver.ACTION_PAUSE)
            }
        }

        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(40), dp(20), dp(24))
            setBackgroundColor(Color.WHITE)
        }

        // Title row
        val title = TextView(this).apply {
            text = "Focus · $label"
            textSize = 16f
            setTextColor(Color.parseColor("#141414"))
        }
        root.addView(title, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))

        val status = TextView(this).apply {
            text = if (paused) "Paused" else "Session running"
            textSize = 12f
            setTextColor(Color.parseColor("#666666"))
        }
        root.addView(status, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))

        // Buttons row
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(16), 0, 0)
        }
        val toggle = Button(this).apply {
            text = if (paused) "Resume" else "Pause"
            isAllCaps = false
        }
        val end = Button(this).apply {
            text = "End"
            isAllCaps = false
            setTextColor(Color.parseColor("#E5484D"))
        }
        row.addView(toggle, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply {
            marginEnd = dp(10)
        })
        row.addView(end, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        root.addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))

        setContentView(root)

        toggle.setOnClickListener {
            toggleAction()
            finish()
        }
        end.setOnClickListener {
            sendAction(FocusSessionActionReceiver.ACTION_END)
            finish()
        }

        // Spring bounce: enter with an overshoot so the panel visibly
        // springs out of the chip, and exit springs back up.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            root.scaleX = 0.85f
            root.scaleY = 0.85f
            root.translationY = -dp(60).toFloat()
            root.animate()
                .scaleX(1f)
                .scaleY(1f)
                .translationY(0f)
                .setDuration(420L)
                .setInterpolator(SpringInterpolator(0.62f))
                .start()
        }
    }

    private fun sendAction(action: String) {
        val intent = Intent(this, FocusSessionActionReceiver::class.java).apply {
            this.action = action
        }
        sendBroadcast(intent)
    }

    private fun dp(v: Int): Int =
        (v * resources.displayMetrics.density).toInt()
}
