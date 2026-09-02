package com.ulimit.app

import android.app.AutomaticZenRule
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.service.notification.ConditionProviderService
import android.service.notification.ZenDeviceEffects
import android.service.notification.ZenPolicy

/**
 * System-wide bedtime grayscale, backed by the Android 15+ Do-Not-Disturb
 * device-effect API.
 *
 * A third-party app cannot access the secure-settings color-adjustment
 * keys (daltonizer) — those need WRITE_SECURE_SETTINGS. The sanctioned
 * path is an AutomaticZenRule that attaches a [ZenDeviceEffects] grayscale
 * effect: while the rule is ACTIVE, the system renders the screen
 * grayscale. The rule's own notification policy is deliberately
 * allow-everything so it never silences anything; the state (active only
 * during the bedtime window) is driven by [BedtimeConditionProvider].
 */
object BedtimeEffects {

    /** Single condition id shared by the rule and the provider. */
    val CONDITION_ID: Uri = Uri.parse("provider://com.ulimit.app/ulimit_bedtime_grayscale")

    private const val RULE_NAME = "Ulimit bedtime grayscale"

    /**
     * Creates (or refreshes) the grayscale rule when [enabled], removes it
     * otherwise. Idempotent; safe to call at window edges and on toggle.
     */
    fun setGrayscale(context: Context, enabled: Boolean) {
        // ZenDeviceEffects landed in API 35 (Android 15).
        if (Build.VERSION.SDK_INT < 35) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!nm.isNotificationPolicyAccessGranted) return
        try {
            val ruleId = ruleId(nm)
            if (enabled) {
                if (ruleId == null) {
                    nm.addAutomaticZenRule(buildRule())
                } else {
                    // Refresh in case the user's DND settings changed the
                    // rule while we were away (e.g. they deleted it).
                    nm.updateAutomaticZenRule(ruleId, buildRule())
                }
            } else {
                if (ruleId != null) nm.removeAutomaticZenRule(ruleId)
            }
        } catch (_: Exception) {
            // Best-effort: OEMs may restrict app-created rules.
        }
    }

    /** Asks the system to re-bind our condition provider (re-evaluates
     *  the window state after time changes / settings toggles). */
    fun rebindProvider(context: Context) {
        if (Build.VERSION.SDK_INT < 35) return
        try {
            ConditionProviderService.requestRebind(
                ComponentName(context, BedtimeConditionProvider::class.java)
            )
        } catch (_: Exception) {
        }
    }

    private fun ruleId(nm: NotificationManager): String? =
        nm.getAutomaticZenRules().entries
            .firstOrNull { it.value.conditionId == CONDITION_ID }
            ?.key

    private fun buildRule(): AutomaticZenRule =
        AutomaticZenRule.Builder(RULE_NAME, CONDITION_ID)
            .setName(RULE_NAME)
            // Allow-everything policy: the rule carries only the
            // grayscale device effect, never notification silencing.
            .setZenPolicy(
                ZenPolicy.Builder()
                    .allowAllSounds()
                    .showAllVisualEffects()
                    .allowPriorityChannels(true)
                    .allowConversations(ZenPolicy.CONVERSATION_SENDERS_ANYONE)
                    .allowMessages(ZenPolicy.PEOPLE_TYPE_ANYONE)
                    .allowCalls(ZenPolicy.PEOPLE_TYPE_ANYONE)
                    .allowRepeatCallers(true)
                    .allowAlarms(true)
                    .allowMedia(true)
                    .allowSystem(true)
                    .allowEvents(true)
                    .allowReminders(true)
                    .build()
            )
            .setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALL)
            .setDeviceEffects(
                ZenDeviceEffects.Builder()
                    .setShouldDisplayGrayscale(true)
                    .build()
            )
            .setEnabled(true)
            .build()
}
