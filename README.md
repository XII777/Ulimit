# Ulimit

Local-first focus & screen-time control for Android. No accounts, no cloud —
everything lives on-device.

## Getting it running

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

This is a working scaffold, not a finished app. It establishes the
patterns; the remaining 12+ screens from the mockups follow the same
shape as Home/Focus/Limits below.

## Why these choices

**Riverpod over setState/Provider/Bloc.** `StreamProvider` on top of
Drift's `.watch()` means the UI updates when the DB changes, with zero
manual "refresh" calls anywhere. Providers are scoped narrowly
(`todayScreenTimeProvider`, not one giant `AppState`) so a usage-count
change doesn't rebuild the whole Home screen — only the ring.

**Drift over shared_preferences/Hive/raw sqflite.** Real SQL, real
migrations, compile-time-checked queries. Given the data model here
(restriction groups ↔ apps, sessions with start/end, daily usage rows)
this is genuinely relational data, not key-value — the right tool.

**go_router with a custom `PageRouteBuilder` for "morphing."** No
`animations` package, no `page_transition` package. A fade + slight
scale via `CurvedAnimation` costs one compositor layer, stays at 60fps
on a Pixel 4a-class device, and avoids the two most common jank sources
in Flutter nav: `BackdropFilter` blur mid-transition and chained `Hero`
flights on complex subtrees (our ring widgets).

**`ShellRoute` for the nav bar.** The floating pill bar is mounted once
and stays alive across tab switches — it does NOT get rebuilt (and its
`AnimatedContainer` re-triggered) every time you tap a tab. This is the
single most common performance mistake in bottom-nav Flutter apps.

**One `CustomPainter` for the ring motif**, reused via `LimitRing`
everywhere (Home budget, Focus countdown, group allowance, bedtime
arc), instead of four hand-rolled `Stack`+`Container` versions. One
thing to profile, one thing to optimize, visually identical everywhere
per the design system.

**No account/auth layer anywhere in main() or the router.** Per
product requirement — everything is local. `Profile` table is a
one-row local settings record, not a user table.

## Performance budget (why "don't lag" is actually addressed, not just claimed)

- `const` constructors used throughout static subtrees (icons, chip
  labels, dividers) so Flutter's widget-diffing can skip them entirely.
- `LazyDatabase` defers SQLite file I/O off the cold-start path.
- Timers (`FocusScreen`) are always cancelled in `dispose()` — audited
  this explicitly since a leaked periodic timer is the most common
  cause of Flutter apps slowing down the longer they stay open.
- `shouldRepaint` on the ring painter is value-gated, not
  unconditionally `true`.
- No `BackdropFilter` (blur) is used during any animated transition —
  only as a static effect on already-settled screens (e.g. the glass
  share-card), where it costs one paint, not one paint per frame.

## What's not built yet (same pattern, straightforward to extend)

- `features/bedtime/`, `features/settings/`, `features/onboarding/`,
  `features/blocking_overlay/`, `features/share_card/` — UI screens
  only; no new architectural decisions needed, copy the Home/Limits
  pattern.
- `android/` platform channel: `AccessibilityService` implementation
  (usage detection + block-screen overlay) and `DeviceAdminReceiver`
  (uninstall/force-stop protection). This is the one piece that's
  genuinely Android-native Kotlin, not Dart — will need its own file
  when you're ready for it.
- Score calculation service (`ScoreLog` table exists; the weighted
  formula from the mockup isn't implemented as code yet).
- `drift_dev` code generation: run `dart run build_runner build` once
  dependencies are pulled, to generate `app_database.g.dart`.

## Getting it running

```
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

## Pushing to GitHub

```bash
git init
git add .
git commit -m "Initial scaffold: theme, router, Drift schema, Home/Focus/Limits"
git branch -M main
git remote add origin https://github.com/<your-username>/ulimit.git
git push -u origin main
```

CI (`.github/workflows/ci.yml`) runs `flutter analyze`, `flutter test`, and
builds a release APK on every push to `main` — check the **Actions** tab
after your first push. The APK is uploaded as a workflow artifact even
without signing configured, so you can sideload-test it immediately.

