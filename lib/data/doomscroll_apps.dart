/// The doomscroll preset: Android package names of the major
/// infinite-feed / short-video apps, blocked with one switch from the
/// Focus screen's CONTROLS sheet.
///
/// Researched from each app's Play Store manifest ID. Blocking is
/// whole-app (the enforcement engine has no way to block an in-app
/// section like Reels or Shorts separately), so blocking YouTube blocks
/// the full app — the canonical trade-off every doomscroll blocker
/// (one sec, Opal, ScreenZen) makes.
///
/// Packages that aren't installed on the device simply never match —
/// the list is safe to keep as a superset across devices.
const List<String> kDoomscrollPackages = [
  // Short video
  'com.zhiliaoapp.musically', // TikTok
  'com.google.android.youtube', // YouTube (Shorts)
  // Meta
  'com.instagram.android', // Instagram (Reels)
  'com.instagram.lite', // Instagram Lite
  'com.instagram.barcelona', // Threads
  'com.facebook.katana', // Facebook
  'com.facebook.lite', // Facebook Lite
  // Text & link feeds
  'com.twitter.android', // X (Twitter)
  'com.twitter.android.lite', // X Lite
  'com.reddit.frontpage', // Reddit
  'com.tumblr', // Tumblr
  'com.quora.android', // Quora
  'com.linkedin.android', // LinkedIn feed
  // Image & live feeds
  'com.pinterest', // Pinterest
  'com.snapchat.android', // Snapchat (Spotlight/Discover)
  'tv.twitch.android.app', // Twitch
  'com.ninegag.android.app', // 9GAG
];

/// Platform metadata for the doomscroll picker: package, display name,
/// feed label (what one "open" is: a Reels/Shorts/scroll session) and
/// whether the app is primarily a short-video feed.
class DoomscrollPlatform {
  const DoomscrollPlatform(
    this.packageName,
    this.name,
    this.feedLabel, {
    this.shortVideo = false,
  });

  final String packageName;
  final String name;
  final String feedLabel;

  /// True for the short-video platforms (TikTok/Shorts/Reels-style) —
  /// sorted to the top of the picker, tinted differently in analytics.
  final bool shortVideo;
}

const List<DoomscrollPlatform> kDoomscrollPlatforms = [
  DoomscrollPlatform('com.zhiliaoapp.musically', 'TikTok', 'TikTok opens', shortVideo: true),
  DoomscrollPlatform('com.google.android.youtube', 'YouTube Shorts', 'Shorts watched', shortVideo: true),
  DoomscrollPlatform('com.instagram.android', 'Instagram Reels', 'Reels sessions', shortVideo: true),
  DoomscrollPlatform('com.instagram.lite', 'Instagram Lite', 'Reels sessions', shortVideo: true),
  DoomscrollPlatform('com.instagram.barcelona', 'Threads', 'Scroll sessions'),
  DoomscrollPlatform('com.facebook.katana', 'Facebook', 'Feed opens'),
  DoomscrollPlatform('com.facebook.lite', 'Facebook Lite', 'Feed opens'),
  DoomscrollPlatform('com.twitter.android', 'X (Twitter)', 'Feed opens'),
  DoomscrollPlatform('com.twitter.android.lite', 'X Lite', 'Feed opens'),
  DoomscrollPlatform('com.reddit.frontpage', 'Reddit', 'Feed opens'),
  DoomscrollPlatform('com.tumblr', 'Tumblr', 'Feed opens'),
  DoomscrollPlatform('com.quora.android', 'Quora', 'Feed opens'),
  DoomscrollPlatform('com.linkedin.android', 'LinkedIn', 'Feed opens'),
  DoomscrollPlatform('com.pinterest', 'Pinterest', 'Scroll sessions'),
  DoomscrollPlatform('com.snapchat.android', 'Snapchat', 'Spotlight opens', shortVideo: true),
  DoomscrollPlatform('tv.twitch.android.app', 'Twitch', 'Stream opens'),
  DoomscrollPlatform('com.ninegag.android.app', '9GAG', 'Scroll sessions'),
];

DoomscrollPlatform? doomscrollPlatformFor(String packageName) {
  for (final p in kDoomscrollPlatforms) {
    if (p.packageName == packageName) return p;
  }
  return null;
}

