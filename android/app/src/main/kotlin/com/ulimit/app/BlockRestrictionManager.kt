package com.ulimit.app

import android.content.Context
import android.util.Log

/** A blocked app's evaluation result — mirrors Mindful's RestrictionState:
 *  whether the app is restricted right now and how long the restriction
 *  still lasts (0/MAX → until the user lifts it). */
data class BlockState(
    val reason: String,
    val timeLeftMillis: Long,
) {
    val isBlocked: Boolean get() = true
}

/**
 * Evaluates whether an app is blocked — Mindful's `RestrictionManager`
 * role. Mindful reads its own local restriction tables plus tracked usage;
 * our policy (manual blocks, daily/group limits, focus, bedtime) lives in
 * the Dart engine, which pushes a snapshot to native and is re-evaluated
 * here via [PolicySnapshot.shouldBlock] — the same "decision per app"
 * pattern, with the snapshot as the source of truth.
 */
class BlockRestrictionManager(private val context: Context) {

    fun evaluate(pkg: String): BlockState? {
        val now = System.currentTimeMillis()
        val verdict = PolicySnapshot.shouldBlock(context, pkg, now) ?: return null
        if (PolicySnapshot.isDebugBuild(context)) {
            Log.d("UlimitBlock", "restriction: $pkg => ${verdict.reason}")
        }
        val left = if (verdict.untilMillis <= 0L) Long.MAX_VALUE else verdict.untilMillis - now
        return BlockState(reason = verdict.reason, timeLeftMillis = left)
    }
}
