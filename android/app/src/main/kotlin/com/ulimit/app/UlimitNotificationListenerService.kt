package com.ulimit.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Holds notifications while a focus session with "pause notifications"
 * is running. Held notifications are cancelled from the shade, kept in
 * memory, and re-posted when the session ends. Contents never leave the
 * device.
 *
 * Calls and alarms (CATEGORY_CALL / CATEGORY_ALARM / CATEGORY_REMINDER)
 * are never held, and neither are Ulimit's own notifications — silencing
 * an alarm clock would defeat the point of a calm utility.
 */
class UlimitNotificationListenerService : NotificationListenerService() {

    companion object {
        private const val CHANNEL_ID = "ulimit_held"
        private const val SUMMARY_ID = 2001
    }

    private data class HeldNotification(val key: String, val id: Int, val notification: Notification)

    private val held = ConcurrentLinkedQueue<HeldNotification>()

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        if (!shouldHold()) {
            releaseAll()
            return
        }
        if (isAllowlisted(sbn)) return
        if (sbn.packageName == packageName) return

        val entry = HeldNotification(sbn.key, sbn.id, sbn.notification)
        if (held.contains(entry)) return
        held.add(entry)

        try {
            cancelNotification(sbn.key)
            postSummary()
        } catch (e: Exception) {
            Log.w("UlimitNotif", "hold failed", e)
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        // Nothing to do — a removed notification is simply gone.
    }

    private fun shouldHold(): Boolean {
        val snapshot = PolicySnapshot.read(this) ?: return false
        val focus = snapshot.focus ?: return false
        return focus.pauseNotifications && focus.untilMillis > System.currentTimeMillis()
    }

    private fun isAllowlisted(sbn: StatusBarNotification): Boolean {
        val category = sbn.notification.category
        if (category == Notification.CATEGORY_CALL ||
            category == Notification.CATEGORY_ALARM ||
            category == Notification.CATEGORY_REMINDER
        ) {
            return true
        }
        // Ongoing media/system notifications are never held either.
        return (sbn.notification.flags and Notification.FLAG_ONGOING_EVENT) != 0
    }

    private fun postSummary() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Held notifications", NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("Ulimit")
            .setContentText("${held.size} notifications held · available after focus")
            .setSmallIcon(android.R.drawable.ic_media_pause)
            .setOngoing(false)
            .setContentIntent(pending)
            .build()
        nm.notify(SUMMARY_ID, notification)
    }

    private fun releaseAll() {
        if (held.isEmpty()) return
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        // Ids are per-posting-package: re-post under our own namespace
        // with offset ids so different apps' notifications don't collide.
        var offset = 0
        for (h in held) {
            try {
                nm.notify(SUMMARY_ID + 100 + (offset++), h.notification)
            } catch (_: Exception) {
            }
        }
        held.clear()
        nm.cancel(SUMMARY_ID)
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        // If focus ended while we were dead, drop stale holds.
        if (!shouldHold()) held.clear()
    }

    override fun onDestroy() {
        releaseAll()
        super.onDestroy()
    }
}
