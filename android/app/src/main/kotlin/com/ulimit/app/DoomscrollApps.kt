package com.ulimit.app

/**
 * The doomscroll platform list + feed-surface markers, mirrored from
 * Dart's lib/data/doomscroll_apps.dart.
 *
 * Two enforcement tiers:
 *  - FEED-NATIVE packages (Reddit, Pinterest…): the feed IS the app —
 *    budget blocking happens at package level via [PolicySnapshot].
 *  - SECTION-LEVEL packages (Instagram, YouTube, TikTok…): the
 *    accessibility detector scans the visible node tree for [markers]
 *    identifying the Reels/Shorts/For-You surface and ejects ONLY the
 *    scroll (notice + BACK). The rest of the app stays usable.
 *
 * Markers are matched case-insensitively against node text and
 * contentDescription. [requireSelected] = the marker node must also be
 * SELECTED (bottom-nav semantics) so an unselected "Reels" tab label
 * can never false-positive; presence-only markers ("For You") are ones
 * that exist solely on the feed page itself.
 */
object DoomscrollApps {

    data class FeedSurface(
        val pkg: String,
        val markers: List<String>,
        val requireSelected: Boolean,
    )

    val feedSurfaces: List<FeedSurface> = listOf(
        FeedSurface("com.instagram.android", listOf("Reels"), true),
        FeedSurface("com.instagram.lite", listOf("Reels"), true),
        FeedSurface("com.google.android.youtube", listOf("Shorts"), true),
        // "For You" exists only on the video-feed page (the tab itself
        // is called Home) — presence is specific enough.
        FeedSurface("com.zhiliaoapp.musically", listOf("For You"), false),
        FeedSurface("com.instagram.barcelona", listOf("For you"), false),
        FeedSurface("com.facebook.katana", listOf("Reels & short videos", "Reels and short videos"), false),
        FeedSurface("com.facebook.lite", listOf("Reels & short videos", "Reels and short videos"), false),
        FeedSurface("com.twitter.android", listOf("For you"), true),
        FeedSurface("com.twitter.android.lite", listOf("For you"), true),
        FeedSurface("com.snapchat.android", listOf("Spotlight"), true),
    )

    // Feed-native packages: budget blocking at package level.
    val feedNativePackages: Set<String> = setOf(
        "com.reddit.frontpage", // Reddit
        "com.tumblr", // Tumblr
        "com.quora.android", // Quora
        "com.linkedin.android", // LinkedIn feed
        "com.pinterest", // Pinterest
        "tv.twitch.android.app", // Twitch
        "com.ninegag.android.app" // 9GAG
    )

    val sectionPackages: Set<String> = feedSurfaces.map { it.pkg }.toSet()

    fun isSectionLevelPackage(pkg: String?): Boolean = pkg != null && pkg in sectionPackages

    fun isFeedNativePackage(pkg: String?): Boolean = pkg != null && pkg in feedNativePackages

    fun feedMarkersFor(pkg: String): List<String> =
        feedSurfaces.firstOrNull { it.pkg == pkg }?.markers ?: emptyList()

    fun markersRequireSelectedFor(pkg: String): Boolean =
        feedSurfaces.firstOrNull { it.pkg == pkg }?.requireSelected ?: false
}
