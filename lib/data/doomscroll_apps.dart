/// The doomscroll preset: Android package names of the major
/// infinite-feed / short-video apps, managed from the Focus screen's
/// CONTROLS sheet and the Doomscroll page.
///
/// Researched from each app's Play Store manifest ID.
///
/// Two enforcement tiers:
///  - SECTION-LEVEL platforms (markers non-empty): the accessibility
///    layer detects the Reels/Shorts/For-You surface via visible
///    markers and ejects only the scroll — the rest of the app (DMs,
///    search, profile…) stays fully usable.
///  - FEED-NATIVE platforms (no markers): the feed IS the app, so the
///    daily budget blocks the app itself via the engine.
///
/// Packages that aren't installed on the device simply never match —
/// the list is safe to keep as a superset across devices.
class DoomscrollPlatform {
  const DoomscrollPlatform(
    this.packageName,
    this.name,
    this.feedLabel, {
    this.sectionLevel = false,
    this.feedMarkers = const [],
    this.markersRequireSelected = false,
  });

  final String packageName;
  final String name;
  final String feedLabel;

  /// True when only the short-video SECTION is blocked (accessibility
  /// marker detection) — the app itself stays usable.
  final bool sectionLevel;

  /// Visible-text markers that identify the feed surface (matched
  /// case-insensitively against node text/contentDescription).
  final List<String> feedMarkers;

  /// When true a marker only counts if the matching node is the
  /// SELECTED element (bottom-nav/tab semantics) — prevents false
  /// positives from unselected tab labels.
  final bool markersRequireSelected;
}

const List<DoomscrollPlatform> kDoomscrollPlatforms = [
  // --- Section-level: reels/shorts scroll blocked, app usable ---------
  DoomscrollPlatform(
    'com.instagram.android',
    'Instagram Reels',
    'Reels sessions',
    sectionLevel: true,
    feedMarkers: ['Reels'],
    markersRequireSelected: true,
  ),
  DoomscrollPlatform(
    'com.instagram.lite',
    'Instagram Lite',
    'Reels sessions',
    sectionLevel: true,
    feedMarkers: ['Reels'],
    markersRequireSelected: true,
  ),
  DoomscrollPlatform(
    'com.google.android.youtube',
    'YouTube Shorts',
    'Shorts sessions',
    sectionLevel: true,
    feedMarkers: ['Shorts'],
    markersRequireSelected: true,
  ),
  DoomscrollPlatform(
    'com.zhiliaoapp.musically',
    'TikTok',
    'TikTok sessions',
    sectionLevel: true,
    // "For You" only exists on the video-feed page (the tab itself is
    // called Home), so plain presence is specific enough.
    feedMarkers: ['For You'],
  ),
  DoomscrollPlatform(
    'com.instagram.barcelona',
    'Threads',
    'Scroll sessions',
    sectionLevel: true,
    feedMarkers: ['For you'],
  ),
  DoomscrollPlatform(
    'com.facebook.katana',
    'Facebook Reels',
    'Reels sessions',
    sectionLevel: true,
    feedMarkers: ['Reels & short videos', 'Reels and short videos'],
  ),
  DoomscrollPlatform(
    'com.facebook.lite',
    'Facebook Lite',
    'Reels sessions',
    sectionLevel: true,
    feedMarkers: ['Reels & short videos', 'Reels and short videos'],
  ),
  DoomscrollPlatform(
    'com.twitter.android',
    'X (Twitter)',
    'For-You sessions',
    sectionLevel: true,
    feedMarkers: ['For you'],
    markersRequireSelected: true,
  ),
  DoomscrollPlatform(
    'com.twitter.android.lite',
    'X Lite',
    'For-You sessions',
    sectionLevel: true,
    feedMarkers: ['For you'],
    markersRequireSelected: true,
  ),
  DoomscrollPlatform(
    'com.snapchat.android',
    'Snapchat Spotlight',
    'Spotlight sessions',
    sectionLevel: true,
    feedMarkers: ['Spotlight'],
    markersRequireSelected: true,
  ),
  // --- Feed-native: the feed IS the app, whole-app budget -------------
  DoomscrollPlatform('com.reddit.frontpage', 'Reddit', 'Feed opens'),
  DoomscrollPlatform('com.tumblr', 'Tumblr', 'Feed opens'),
  DoomscrollPlatform('com.quora.android', 'Quora', 'Feed opens'),
  DoomscrollPlatform('com.linkedin.android', 'LinkedIn', 'Feed opens'),
  DoomscrollPlatform('com.pinterest', 'Pinterest', 'Feed opens'),
  DoomscrollPlatform('tv.twitch.android.app', 'Twitch', 'Stream opens'),
  DoomscrollPlatform('com.ninegag.android.app', '9GAG', 'Scroll sessions'),
];

final List<String> kDoomscrollPackages = [
  for (final p in kDoomscrollPlatforms) p.packageName,
];

DoomscrollPlatform? doomscrollPlatformFor(String packageName) {
  for (final p in kDoomscrollPlatforms) {
    if (p.packageName == packageName) return p;
  }
  return null;
}

/// Section-level platforms are governed by the accessibility feed
/// detector, never by the engine's package-level block.
bool isSectionLevelPlatform(String packageName) =>
    doomscrollPlatformFor(packageName)?.sectionLevel ?? false;
