package com.ulimit.app

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Fired by AlarmManager at the bedtime window edges. Applies or clears
 * Do Not Disturb (when policy access is granted) and keeps the flag in
 * sync with the snapshot. Re-schedules the next occurrence so the pair
 * of alarms repeats daily without any external scheduler.
 */
class BedtimeAlarmReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_BEDTIME_START = "com.ulimit.app.BEDTIME_START"
        const val ACTION_BEDTIME_END = "com.ulimit.app.BEDTIME_END"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val wantsDnd = intent.action == ACTION_BEDTIME_START
        PolicySnapshot.prefs(context).edit()
            .putBoolean(PolicySnapshot.KEY_BEDTIME_ACTIVE, wantsDnd)
            .apply()

        if (nm.isNotificationPolicyAccessGranted) {
            try {
                nm.setInterruptionFilter(
                    if (wantsDnd) NotificationManager.INTERRUPTION_FILTER_PRIORITY
                    else NotificationManager.INTERRUPTION_FILTER_ALL
                )
            } catch (_: SecurityException) {
                // Policy access was revoked since scheduling — nothing
                // else we can do from a receiver.
            }
        }

        // Grayscale system effect, driven by the same edges. At the
        // start the rule is created (if the setting is on) and the
        // provider is re-bound to publish the in-window state; at the
        // end the provider republishes FALSE (the rule stays but is
        // inert while outside the window).
        val snapshot = PolicySnapshot.read(context)
        val wantsGrayscale = wantsDnd && snapshot?.bedtime?.grayscale == true
        if (wantsGrayscale) {
            BedtimeEffects.setGrayscale(context, true)
        }
        BedtimeEffects.rebindProvider(context)

        // VPN state can change at the boundary (bedtime internet block);
        // nudge the service so it re-reads the snapshot if running.
        if (UlimitVpnService.isRunning) {
            val vpnIntent = Intent(context, UlimitVpnService::class.java).apply {
                action = UlimitVpnService.ACTION_RELOAD
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // startService() from a background receiver throws
                // IllegalStateException; foreground-service start is the
                // sanctioned path, and the service promotes itself first.
                context.startForegroundService(vpnIntent)
            } else {
                context.startService(vpnIntent)
            }
        }
    }
}
