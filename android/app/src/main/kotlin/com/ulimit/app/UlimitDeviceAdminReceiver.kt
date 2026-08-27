package com.ulimit.app

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/// No custom policy enforcement — being an active admin at all is what
/// blocks a casual uninstall/force-stop. onEnabled/onDisabled are
/// logged, not acted on, since Invincible Mode's actual "don't let the
/// user undo this" logic lives in Dart against the RestrictionGroups
/// table, not here.
class UlimitDeviceAdminReceiver : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        super.onEnabled(context, intent)
        Log.i("Ulimit", "Device admin enabled")
    }

    override fun onDisabled(context: Context, intent: Intent) {
        super.onDisabled(context, intent)
        Log.i("Ulimit", "Device admin disabled")
    }
}
