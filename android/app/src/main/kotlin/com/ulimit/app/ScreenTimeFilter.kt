package com.ulimit.app

/**
 * Screen-time exclusions — the Kotlin mirror of
 * lib/data/screen_time_filter.dart (isExcludedFromScreenTime). The two
 * lists MUST stay in sync: Dart owns what is WRITTEN into the app_usage
 * table, Kotlin owns what the hourly UsageEvents attribution counts.
 * Divergence made the hourly bars count launcher time on non-Pixel
 * devices while the daily ring (DB-filtered) excluded it — the two
 * views disagreed with each other and with Digital Wellbeing.
 */
object ScreenTimeFilter {

    private val excludedPackages = setOf(
        "com.android.launcher",
        "com.android.launcher2",
        "com.android.launcher3",
        "com.google.android.apps.nexuslauncher", // Pixel / stock AOSP
        "com.sec.android.app.launcher",          // Samsung One UI
        "com.samsung.android.launcher",
        "com.miui.home",                          // Xiaomi / Redmi / POCO
        "com.oplus.launcher",                     // OnePlus / Oppo (ColorOS 13+)
        "com.coloros.launcher",                   // Oppo
        "com.bbk.launcher",                       // Vivo / BBK
        "com.bbk.launcher2",
        "com.vivo.launcher",
        "com.huawei.android.launcher",            // Huawei
        "com.hihonor.launcher",                   // Honor
        "com.oneplus.launcher",
        "com.nothing.launcher",                   // Nothing Phone
        "org.lineageos.launcher3",                // LineageOS
    )

    /** True for packages that must NEVER count as screen time: the
     *  home screen/launcher, OS chrome (System UI), and Ulimit itself. */
    fun isExcludedFromScreenTime(packageName: String?): Boolean {
        if (packageName.isNullOrEmpty()) return true
        if (packageName == "com.ulimit.app") return true
        if (packageName == "com.android.systemui") return true
        if (packageName in excludedPackages) return true
        // Generic catch for custom/unknown launchers — every home-shell
        // package carries "launcher" in its name.
        return packageName.contains("launcher")
    }
}
