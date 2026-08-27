package com.ulimit.app

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/// Grants the permission surface the onboarding screen checks against
/// (BIND_NOTIFICATION_LISTENER_SERVICE requires an actual declared
/// service, not just a manifest permission). The real batching/muting
/// policy — hold, silence, or release based on Bedtime/Focus state — is
/// intentionally not implemented yet; wiring it needs the
/// RestrictionGroups + BedtimeSchedule state to be readable from native
/// code, which is the next slice of this feature, not this one.
class UlimitNotificationListenerService : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        // Intentionally empty for now — see class doc.
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        // Intentionally empty for now — see class doc.
    }
}
