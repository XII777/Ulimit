package com.ulimit.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives Pause / Resume / End from the Focus Session system
 * notification and routes them into the Dart FocusController through
 * the platform channel — the SAME controller the in-app buttons use,
 * so there is one source of truth for session state.
 *
 * Works whether or not the app process is alive: if the Activity
 * engine is cached it is reused; otherwise a headless engine is
 * spawned on the "backgroundMain" entrypoint.
 */
class FocusSessionActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_PAUSE = "com.ulimit.app.focus.PAUSE"
        const val ACTION_RESUME = "com.ulimit.app.focus.RESUME"
        const val ACTION_END = "com.ulimit.app.focus.END"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = when (intent.action) {
            ACTION_PAUSE -> "pause"
            ACTION_RESUME -> "resume"
            ACTION_END -> "end"
            else -> return
        }

        val pending = goAsync()
        Thread {
            try {
                val engine = FocusIndicatorService.ensureEngine(context)
                val channel = io.flutter.plugin.common.MethodChannel(
                    engine.dartExecutor.binaryMessenger,
                    "com.ulimit.app/enforcement"
                )
                // The Dart handler performs the action through the
                // FocusController, re-pushes the enforcement snapshot and
                // updates/removes the indicator via the same channel.
                channel.invokeMethod(
                    "focusAction",
                    mapOf("action" to action),
                    object : io.flutter.plugin.common.MethodChannel.Result {
                        override fun success(result: Any?) {
                            pending.finish()
                        }

                        override fun error(code: String, message: String?, details: Any?) {
                            pending.finish()
                        }

                        override fun notImplemented() {
                            pending.finish()
                        }
                    }
                )
            } catch (e: Exception) {
                pending.finish()
            }
        }.start()
    }
}
