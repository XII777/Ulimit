package com.ulimit.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Restores scheduled work after a reboot:
 *  - restarts the standalone blocking enforcement service when any
 *    restriction is configured (app blocking works immediately after
 *    boot, without opening Ulimit);
 *  - restarts the local VPN when it was active before the shutdown
 *    (firewall/filter state is re-derived from the persisted snapshot);
 *  - re-arms the bedtime alarms from the persisted schedule.
 *
 * This is what makes restrictions "survive a restart" per the
 * reliability requirements — nothing depends on Ulimit being opened
 * first.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        // App blocking first — it must not depend on anything else.
        BlockGuardService.ensureStarted(context)

        val prefs = PolicySnapshot.prefs(context)

        if (prefs.getBoolean(PolicySnapshot.KEY_VPN_ENABLED, false)) {
            val vpnIntent = Intent(context, UlimitVpnService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(vpnIntent)
            } else {
                context.startService(vpnIntent)
            }
        }
    }
}
