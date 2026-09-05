package com.ulimit.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * Receives Pause / Resume / End from the Focus Session system
 * notification and routes them into the Dart FocusController through
 * the platform channel — the SAME controller the in-app buttons use,
 * so there is one source of truth for session state.
 *
 * Works whether or not the app process is alive: if the Activity
 * engine is cached it is reused; otherwise a headless engine is
 * spawned on the "backgroundMain" entrypoint.
 *
 * THREADING: everything here marshals to the main Looper. Flutter's
 * engine construction and MethodChannel calls must run on a thread
 * with (and pumping) the platform Looper — calling them from a bare
 * worker thread (the old behavior) meant the invokeMethod died
 * silently and the notification buttons did nothing. A watchdog
 * finishes the async receiver token even if Dart never answers, so
 * the broadcast can never hang.
 */
class FocusSessionActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_PAUSE = "com.ulimit.app.focus.PAUSE"
        const val ACTION_RESUME = "com.ulimit.app.focus.RESUME"
        const val ACTION_END = "com.ulimit.app.focus.END"
        private const val TIMEOUT_MS = 8000L
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = when (intent.action) {
            ACTION_PAUSE -> "pause"
            ACTION_RESUME -> "resume"
            ACTION_END -> "end"
            else -> return
        }

        val pending = goAsync()
        val main = Handler(Looper.getMainLooper())
        var finished = false
        fun finishOnce() {
            if (finished) return
            finished = true
            pending.finish()
        }

        val watchdog = Runnable { finishOnce() }
        main.postDelayed(watchdog, TIMEOUT_MS)

        main.post {
            try {
                val engine = FocusIndicatorService.ensureEngine(context)
                val channel = io.flutter.plugin.common.MethodChannel(
                    engine.dartExecutor.binaryMessenger,
                    "com.ulimit.app/enforcement"
                )
                // The Dart handler performs the action through the
                // FocusController, re-pushes the enforcement snapshot
                // and updates/removes the indicator via the same
                // channel — which is what repaints the pill.
                channel.invokeMethod(
                    "focusAction",
                    mapOf("action" to action),
                    object : io.flutter.plugin.common.MethodChannel.Result {
                        override fun success(result: Any?) {
                            main.removeCallbacks(watchdog)
                            finishOnce()
                        }

                        override fun error(code: String, message: String?, details: Any?) {
                            main.removeCallbacks(watchdog)
                            finishOnce()
                        }

                        override fun notImplemented() {
                            main.removeCallbacks(watchdog)
                            finishOnce()
                        }
                    }
                )
            } catch (e: Exception) {
                main.removeCallbacks(watchdog)
                finishOnce()
            }
        }
    }
}
