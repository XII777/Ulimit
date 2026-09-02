package com.ulimit.app

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Shows and dismisses the full-screen "blocked" alert pop-layer — the
 * same visual the app has always shown (app icon, name, restriction
 * reason, remaining time). It only owns the overlay window: deciding
 * whether an app is restricted and ejecting it is [BlockEngine]'s job,
 * and the overlay's LIFETIME is engine-owned too — it stays up exactly
 * as long as the blocked app is foreground (the old fixed 1400ms
 * self-dismiss let a failed eject expose a usable blocked app).
 *
 * Two window types, one host per enforcement layer:
 *  - TYPE_ACCESSIBILITY_OVERLAY — added by the accessibility service,
 *    needs no extra permission; the primary host.
 *  - TYPE_APPLICATION_OVERLAY — added by [BlockGuardService] when
 *    accessibility is unavailable; needs "Display over other apps".
 *
 * Either way the window is touch-absorbing (no FLAG_NOT_TOUCHABLE, no
 * FLAG_NOT_TOUCH_MODAL on a MATCH_PARENT window), so the blocked app
 * underneath cannot be interacted with.
 */
class BlockOverlayManager(
    private val context: Context,
    private val windowType: Int,
) {

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

    /** @return `true` if the overlay is now displayed for [packageName]. */
    fun showOverlay(packageName: String, verdict: PolicySnapshot.BlockVerdict): Boolean {
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

        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#EE0A0A0B"))
            setPadding(dp(32), dp(32), dp(32), dp(32))
        }

        val iconTile = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(0), dp(40), dp(0), dp(8))
        }
        val iconHolder = android.widget.FrameLayout(context).apply {
            layoutParams = android.view.ViewGroup.LayoutParams(dp(96), dp(96))
        }
        iconHolder.background = android.graphics.drawable.GradientDrawable().apply {
            cornerRadius = dp(20).toFloat()
            color = android.content.res.ColorStateList.valueOf(Color.parseColor("#FFFFFFFF"))
        }
        appIcon?.let {
            iconHolder.addView(
                android.widget.ImageView(context).apply {
                    setImageDrawable(it)
                    layoutParams = android.view.ViewGroup.LayoutParams(dp(64), dp(64))
                }
            )
        }
        iconTile.addView(iconHolder)

        val appNameView = TextView(context).apply {
            text = appName
            setTextColor(Color.parseColor("#F5F5F4"))
            textSize = 24f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(0, dp(20), 0, 0)
        }

        val reasonView = TextView(context).apply {
            text = verdict.reason
            setTextColor(Color.parseColor("#A3A3A6"))
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, dp(12), 0, 0)
        }

        val remainingView = TextView(context).apply {
            setTextColor(Color.parseColor("#F5F5F4"))
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(0, dp(24), 0, dp(10))
        }

        val progressBar = android.widget.ProgressBar(
            context, null, android.R.attr.progressBarStyleHorizontal
        ).apply {
            layoutParams = LinearLayout.LayoutParams(dp(240), dp(8))
            max = 100
            progress = 100
            progressTintList = android.content.res.ColorStateList.valueOf(
                Color.parseColor("#F0F0F0"))
            progressBackgroundTintList = android.content.res.ColorStateList.valueOf(
                Color.parseColor("#3A3A3E"))
        }

        val byline = TextView(context).apply {
            text = "Blocked by Ulimit"
            setTextColor(Color.parseColor("#6B6B6F"))
            textSize = 12f
            gravity = Gravity.CENTER
            setPadding(0, dp(16), 0, 0)
        }

        root.addView(iconTile)
        root.addView(appNameView)
        root.addView(reasonView)
        root.addView(remainingView)
        root.addView(progressBar)
        root.addView(byline)

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
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

        // Remaining-time display drives the bar (0/MAX → manual release).
        // The countdown only updates text — it NEVER dismisses the
        // overlay; expiry settles through BlockEngine's recheck loop.
        val now = System.currentTimeMillis()
        val indefinite = verdict.untilMillis <= 0L
        val totalAtShow = if (indefinite) {
            0L
        } else {
            (verdict.untilMillis - now).coerceAtLeast(1L)
        }

        val countdown = object : Runnable {
            override fun run() {
                if (overlayView == null || overlayPackageName != packageName) return
                if (indefinite) {
                    remainingView.text = "Until manually removed"
                    progressBar.progress = 100
                    return
                }
                val remaining = totalAtShow - (System.currentTimeMillis() - now)
                if (remaining <= 0) {
                    // Expired — the engine settles; freeze the display.
                    remainingView.text = "0s"
                    progressBar.progress = 0
                    return
                }
                remainingView.text = formatRemainingTime(remaining)
                progressBar.progress =
                    ((remaining * 100) / totalAtShow).toInt().coerceIn(0, 100)
                handler.postDelayed(this, 500)
            }
        }
        handler.postDelayed(countdown, 200)
        return shown
    }

    fun dismissOverlay() {
        handler.removeCallbacksAndMessages(null)
        overlayView?.let {
            try {
                windowManager.removeView(it)
            } catch (_: Exception) {
            }
        }
        overlayView = null
        overlayPackageName = null
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
}
