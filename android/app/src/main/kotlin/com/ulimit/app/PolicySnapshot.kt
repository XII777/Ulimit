package com.ulimit.app

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * The single native-side view of Dart's policy state.
 *
 * Dart pushes the full snapshot on every relevant change; native
 * consumers (AccessibilityService overlay, VpnService, BootReceiver,
 * BedtimeAlarmReceiver) read it from SharedPreferences so enforcement
 * survives process death and reboots.
 *
 * Native-side evaluation is deliberately limited to simple, locally
 * computable checks — timestamp expiry, minute-of-day windows, and
 * usage thresholds — so Dart stays the only source of business logic.
 */
object PolicySnapshot {

    /** AGP 8+ no longer generates BuildConfig; use the runtime flag. */
    fun isDebugBuild(context: Context): Boolean =
        (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

    const val PREFS = "ulimit_native"
    const val KEY_SNAPSHOT = "policy_snapshot"
    const val KEY_VPN_ENABLED = "vpn_enabled"
    const val KEY_BEDTIME_ACTIVE = "bedtime_active"

    // Per-day foreground usage accumulated from accessibility events —
    // keyed by package, in seconds. Reset when the local date changes.
    const val KEY_USAGE_DAY = "usage_day"
    const val KEY_USAGE = "usage_json"

    data class ManualRule(val pkg: String, val permanent: Boolean, val untilMillis: Long)

    data class Focus(
        val untilMillis: Long,
        val packages: List<String>,
        val pauseNotifications: Boolean,
        val blockInternet: Boolean
    )

    data class Bedtime(
        val startMinutes: Int,
        val endMinutes: Int,
        val pauseApps: Boolean,
        val blockInternet: Boolean,
        val grayscale: Boolean,
        val packages: List<String>
    )

    data class Group(val limitSeconds: Int, val packages: List<String>)

    data class Snapshot(
        val pushedAtMillis: Long,
        val blockedNow: Map<String, Pair<String, Long>>,
        val manual: List<ManualRule>,
        val limits: Map<String, Int>,
        val groups: List<Group>,
        val focus: Focus?,
        val bedtime: Bedtime?,
        val internetBlocks: List<String>,
        val adultFilterEnabled: Boolean,
        val browserPackages: List<String>
    )

    fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun write(context: Context, json: String) {
        prefs(context).edit().putString(KEY_SNAPSHOT, json).apply()
    }

    fun read(context: Context): Snapshot? {
        val raw = prefs(context).getString(KEY_SNAPSHOT, null) ?: return null
        return try {
            parse(raw)
        } catch (_: Exception) {
            null
        }
    }

    /** True when ANY restriction is configured (manual blocks, limits,
     *  groups, an active focus session, or a bedtime schedule) — the
     *  signal for whether the standalone enforcement service is worth
     *  running. Internet blocks are excluded: that's the VPN layer's
     *  job, and blocking must not depend on it. */
    fun hasActivePolicy(context: Context): Boolean {
        val s = read(context) ?: return false
        if (s.blockedNow.isNotEmpty()) return true
        if (s.manual.isNotEmpty()) return true
        if (s.limits.isNotEmpty()) return true
        if (s.groups.isNotEmpty()) return true
        if ((s.focus?.untilMillis ?: 0L) > System.currentTimeMillis()) return true
        return s.bedtime != null
    }

    fun parse(raw: String): Snapshot {
        val root = JSONObject(raw)

        // Dart's engine verdict: package → (reason, untilMillis). The
        // fast enforcement path — guaranteed to match what the UI shows.
        val blockedNow = mutableMapOf<String, Pair<String, Long>>()
        val blockedArr = root.optJSONArray("blockedNow") ?: JSONArray()
        for (i in 0 until blockedArr.length()) {
            val o = blockedArr.getJSONObject(i)
            blockedNow[o.getString("package")] =
                Pair(o.optString("reason", "Blocked"), o.optLong("untilMillis", 0L))
        }

        val manual = mutableListOf<ManualRule>()
        val manualArr = root.optJSONArray("manual") ?: JSONArray()
        for (i in 0 until manualArr.length()) {
            val o = manualArr.getJSONObject(i)
            manual.add(
                ManualRule(
                    pkg = o.getString("package"),
                    permanent = o.optBoolean("permanent", false),
                    untilMillis = o.optLong("untilMillis", 0L)
                )
            )
        }

        val limits = mutableMapOf<String, Int>()
        val limitsObj = root.optJSONObject("limits") ?: JSONObject()
        val keys = limitsObj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            limits[k] = limitsObj.optInt(k, 0)
        }

        val groups = mutableListOf<Group>()
        val groupsArr = root.optJSONArray("groups") ?: JSONArray()
        for (i in 0 until groupsArr.length()) {
            val o = groupsArr.getJSONObject(i)
            val pkgs = mutableListOf<String>()
            val pkgArr = o.optJSONArray("packages") ?: JSONArray()
            for (j in 0 until pkgArr.length()) pkgs.add(pkgArr.getString(j))
            groups.add(Group(limitSeconds = o.optInt("limitSeconds", 0), packages = pkgs))
        }

        val focusObj = root.optJSONObject("focus")
        val focus = focusObj?.let {
            val pkgs = mutableListOf<String>()
            val pkgArr = it.optJSONArray("packages") ?: JSONArray()
            for (j in 0 until pkgArr.length()) pkgs.add(pkgArr.getString(j))
            Focus(
                untilMillis = it.optLong("untilMillis", 0L),
                packages = pkgs,
                pauseNotifications = it.optBoolean("pauseNotifications", true),
                blockInternet = it.optBoolean("blockInternet", false)
            )
        }

        val bedtimeObj = root.optJSONObject("bedtime")
        val bedtime = bedtimeObj?.let {
            val pkgs = mutableListOf<String>()
            val pkgArr = it.optJSONArray("packages") ?: JSONArray()
            for (j in 0 until pkgArr.length()) pkgs.add(pkgArr.getString(j))
            Bedtime(
                startMinutes = it.optInt("startMinutes", 0),
                endMinutes = it.optInt("endMinutes", 0),
                pauseApps = it.optBoolean("pauseApps", true),
                blockInternet = it.optBoolean("blockInternet", false),
                grayscale = it.optBoolean("grayscale", false),
                packages = pkgs
            )
        }

        val internet = mutableListOf<String>()
        val internetArr = root.optJSONArray("internetBlocks") ?: JSONArray()
        for (i in 0 until internetArr.length()) internet.add(internetArr.getString(i))

        val browsers = mutableListOf<String>()
        val browserArr = root.optJSONArray("browserPackages") ?: JSONArray()
        for (i in 0 until browserArr.length()) browsers.add(browserArr.getString(i))

        return Snapshot(
            pushedAtMillis = root.optLong("pushedAtMillis", 0L),
            blockedNow = blockedNow,
            manual = manual,
            limits = limits,
            groups = groups,
            focus = focus,
            bedtime = bedtime,
            internetBlocks = internet,
            adultFilterEnabled = root.optBoolean("adultFilterEnabled", false),
            browserPackages = browsers
        )
    }

    // ---------------------------------------------------------------------
    // Native-side usage accumulation (for daily limits and groups).
    // Seconds are accumulated here from accessibility foreground events
    // so a daily limit still fires even when Ulimit itself is closed.
    // ---------------------------------------------------------------------

    fun addForegroundSeconds(context: Context, pkg: String, seconds: Int) {
        if (seconds <= 0) return
        val prefs = prefs(context)
        val today = todayKey()
        val usageJson = prefs.getString(KEY_USAGE, null)
        val usage: MutableMap<String, Int> = HashMap()
        val existingDay = prefs.getString(KEY_USAGE_DAY, null)
        if (existingDay == today && usageJson != null) {
            try {
                val o = JSONObject(usageJson)
                val k = o.keys()
                while (k.hasNext()) {
                    val key = k.next()
                    usage[key] = o.optInt(key, 0)
                }
            } catch (_: Exception) {
            }
        } else {
            // New day — the accumulator resets, matching how daily
            // limits reset in the engine.
            prefs.edit().putString(KEY_USAGE_DAY, today).apply()
        }
        usage[pkg] = (usage[pkg] ?: 0) + seconds
        val out = JSONObject()
        for ((k, v) in usage) out.put(k, v)
        prefs.edit().putString(KEY_USAGE, out.toString()).apply()
    }

    fun usageSeconds(context: Context): Map<String, Int> {
        val prefs = prefs(context)
        if (prefs.getString(KEY_USAGE_DAY, null) != todayKey()) return emptyMap()
        val usageJson = prefs.getString(KEY_USAGE, null) ?: return emptyMap()
        return try {
            val o = JSONObject(usageJson)
            val out = mutableMapOf<String, Int>()
            val k = o.keys()
            while (k.hasNext()) {
                val key = k.next()
                out[key] = o.optInt(key, 0)
            }
            out
        } catch (_: Exception) {
            emptyMap()
        }
    }

    private fun todayKey(): String {
        val c = java.util.Calendar.getInstance()
        return "%04d-%02d-%02d".format(c.get(java.util.Calendar.YEAR), c.get(java.util.Calendar.MONTH) + 1, c.get(java.util.Calendar.DAY_OF_MONTH))
    }

    /** Next local midnight in epoch millis — a daily/group limit lasts
     *  until the day resets, mirroring the engine's endOfDayFor. */
    private fun endOfTodayMillis(nowMillis: Long): Long {
        val cal = java.util.Calendar.getInstance().apply {
            timeInMillis = nowMillis
            set(java.util.Calendar.HOUR_OF_DAY, 0)
            set(java.util.Calendar.MINUTE, 0)
            set(java.util.Calendar.SECOND, 0)
            set(java.util.Calendar.MILLISECOND, 0)
            add(java.util.Calendar.DAY_OF_YEAR, 1)
        }
        return cal.timeInMillis
    }

    // ---------------------------------------------------------------------
    // The one decision native makes per foreground app.
    // ---------------------------------------------------------------------

    /** Result of a block evaluation: the reason plus WHEN it ends, so
     *  the overlay can drive its progress bar from the real remaining
     *  time of the restriction (0 = indefinite/until-unrestricted). */
    data class BlockVerdict(val reason: String, val untilMillis: Long)

    fun shouldBlock(context: Context, pkg: String, nowMillis: Long): BlockVerdict? {
        val snapshot = read(context)
        if (snapshot == null) {
            // THE most common silent failure: nothing was ever pushed to
            // native, so every decision here is "not blocked". Surface it.
            if (isDebugBuild(context)) {
                Log.d("UlimitBlock", "shouldBlock($pkg): snapshot is MISSING — blocking is a no-op")
            }
            return null
        }

        // Fast path: Dart's engine already decided this package is
        // blocked. Re-validate the expiry here so a stale snapshot can
        // never block longer than the engine intended, then enforce.
        snapshot.blockedNow[pkg]?.let { (reason, untilMillis) ->
            if (untilMillis == 0L || untilMillis > nowMillis) {
                return BlockVerdict(reason, untilMillis)
            }
        }

        // Structural fallback — covers state that changed while Ulimit
        // was closed (e.g. a daily limit crossed without the app open).
        val nowMin = let {
            val c = java.util.Calendar.getInstance()
            c.get(java.util.Calendar.HOUR_OF_DAY) * 60 + c.get(java.util.Calendar.MINUTE)
        }

        for (rule in snapshot.manual) {
            if (rule.pkg != pkg) continue
            if (rule.permanent) return BlockVerdict("Blocked", 0L)
            if (rule.untilMillis > nowMillis) return BlockVerdict("Blocked", rule.untilMillis)
        }

        val usage = usageSeconds(context)
        val limit = snapshot.limits[pkg]
        if (limit != null && limit > 0 && (usage[pkg] ?: 0) >= limit) {
            // Daily limit: block until the end of the day.
            return BlockVerdict("Daily limit reached", endOfTodayMillis(nowMillis))
        }

        for (group in snapshot.groups) {
            if (pkg !in group.packages) continue
            var used = 0
            for (member in group.packages) used += usage[member] ?: 0
            if (group.limitSeconds > 0 && used >= group.limitSeconds) {
                return BlockVerdict("Group limit reached", endOfTodayMillis(nowMillis))
            }
        }

        val focus = snapshot.focus
        if (focus != null && focus.untilMillis > nowMillis && pkg in focus.packages) {
            return BlockVerdict("Focus session", focus.untilMillis)
        }

        val bedtime = snapshot.bedtime
        if (bedtime != null && bedtime.pauseApps && pkg in bedtime.packages &&
            inWindow(nowMin, bedtime.startMinutes, bedtime.endMinutes)
        ) {
            return BlockVerdict("Bedtime", 0L)
        }

        return null
    }

    fun isInternetBlocked(context: Context, nowMillis: Long): Boolean {
        val snapshot = read(context) ?: return false
        val nowMin = let {
            val c = java.util.Calendar.getInstance()
            c.get(java.util.Calendar.HOUR_OF_DAY) * 60 + c.get(java.util.Calendar.MINUTE)
        }
        if (snapshot.internetBlocks.isNotEmpty()) return true
        val focus = snapshot.focus
        if (focus != null && focus.blockInternet && focus.untilMillis > nowMillis) return true
        val bedtime = snapshot.bedtime
        if (bedtime != null && bedtime.blockInternet &&
            inWindow(nowMin, bedtime.startMinutes, bedtime.endMinutes)
        ) return true
        return false
    }

    fun inWindow(minutesNow: Int, start: Int, end: Int): Boolean {
        val m = minutesNow % (24 * 60)
        return if (start == end) false
        else if (start < end) m >= start && m < end
        else m >= start || m < end
    }
}
