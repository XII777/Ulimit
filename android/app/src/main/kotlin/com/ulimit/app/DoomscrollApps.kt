package com.ulimit.app

/**
 * The doomscroll platform list, mirrored from Dart's
 * lib/data/doomscroll_apps.dart. Kept as a Kotlin mirror (rather than
 * shipped through the snapshot) because open-counting must work before
 * any snapshot is ever pushed.
 */
object DoomscrollApps {
    val packages: Set<String> = setOf(
        "com.zhiliaoapp.musically", // TikTok
        "com.google.android.youtube", // YouTube (Shorts)
        "com.instagram.android", // Instagram (Reels)
        "com.instagram.lite", // Instagram Lite
        "com.instagram.barcelona", // Threads
        "com.facebook.katana", // Facebook
        "com.facebook.lite", // Facebook Lite
        "com.twitter.android", // X (Twitter)
        "com.twitter.android.lite", // X Lite
        "com.reddit.frontpage", // Reddit
        "com.tumblr", // Tumblr
        "com.quora.android", // Quora
        "com.linkedin.android", // LinkedIn feed
        "com.pinterest", // Pinterest
        "com.snapchat.android", // Snapchat (Spotlight/Discover)
        "tv.twitch.android.app", // Twitch
        "com.ninegag.android.app" // 9GAG
    )

    fun isDoomscrollPackage(pkg: String?): Boolean = pkg != null && pkg in packages
}
