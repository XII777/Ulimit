package com.ulimit.app

import android.net.Uri
import android.service.notification.Condition
import android.service.notification.ConditionProviderService

/**
 * Condition provider for the bedtime grayscale rule. The system binds it
 * whenever the rule exists and subscribes to the rule's condition id; we
 * (re-)publish STATE_TRUE only while the bedtime window is active and
 * grayscale is enabled, which is what activates the rule's device effect.
 *
 * Re-evaluation happens on every [onSubscribe] plus the app's own
 * bedtime edge alarms, which call [BedtimeEffects.rebindProvider] — the
 * system then re-subscribes and we compute the fresh state.
 */
class BedtimeConditionProvider : ConditionProviderService() {

    override fun onConnected() {
        // No-op: state is pushed by onSubscribe.
    }

    override fun onSubscribe(conditionId: Uri) {
        publishState(conditionId)
    }

    override fun onUnsubscribe(conditionId: Uri) {
        // No-op: nothing to release.
    }

    override fun onRequestConditions(relevance: Int) {
        publishState(BedtimeEffects.CONDITION_ID)
    }

    private fun publishState(conditionId: Uri) {
        if (conditionId != BedtimeEffects.CONDITION_ID) return

        val snapshot = PolicySnapshot.read(this)
        val bedtime = snapshot?.bedtime
        val ready = snapshot != null && bedtime != null && bedtime.grayscale
        val nowMin = let {
            val c = java.util.Calendar.getInstance()
            c.get(java.util.Calendar.HOUR_OF_DAY) * 60 + c.get(java.util.Calendar.MINUTE)
        }
        val inWindow = ready && PolicySnapshot.inWindow(nowMin, bedtime.startMinutes, bedtime.endMinutes)

        notifyCondition(
            Condition(
                conditionId,
                "Ulimit bedtime",
                "",
                "",
                if (inWindow) Condition.STATE_TRUE else Condition.STATE_FALSE,
                Condition.FLAG_RELEVANT_ALWAYS,
                Condition.SOURCE_SCHEDULE
            )
        )
    }
}
