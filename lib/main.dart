import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/crash/crash_collector.dart';
import 'core/native/enforcement_channel.dart';
import 'core/router/app_router.dart';
import 'core/router/back_button_dispatcher.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/tokens.dart';
import 'data/apps_repository.dart';
import 'data/focus_indicator.dart';
import 'data/permissions_providers.dart';
import 'data/providers.dart';
import 'data/restriction_providers.dart';
import 'data/usage_tracker.dart';
import 'data/website_providers.dart';
import 'features/onboarding/permissions_recovery_screen.dart';
import 'features/onboarding/permissions_screen.dart';

void main() {
  // Crash collection starts before anything else — an error thrown
  // during startup itself is exactly the kind of crash that is hardest
  // to reproduce without a trace.
  unawaited(CrashCollector.initialize());

  // Release builds render build exceptions as BLANK widgets — which
  // looks like "the screen is empty". Surface the actual error text
  // (monochrome card) so any breakage is visible and reportable, and
  // keep it flowing into the crash collector.
  ErrorWidget.builder = (details) {
    final summary = details.exceptionAsString();
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      alignment: Alignment.center,
      child: SingleChildScrollView(
        child: SelectableText(
          'UI error — please report:\n$summary',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  };

  runApp(const ProviderScope(child: UlimitApp()));
}

/// Entry point for the headless Flutter engine the Focus-indicator
/// foreground service creates when the app process is dead and the user
/// taps Pause/Resume/End in the system UI. Registers the platform
/// channels against a private ProviderContainer — no UI, no router.
@pragma('vm:entry-point')
Future<void> backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  unawaited(CrashCollector.initialize());

  EnforcementChannel.setFocusActionHandler((action) async {
    await container.read(focusIndicatorSyncProvider).handleAction(action);
  });
  // Seed the enforcement snapshot from the database so restrictions and
  // the indicator reflect persisted state without the UI engine.
  await container.read(enforcementSyncProvider).push();
  await container.read(focusIndicatorSyncProvider).sync();
}

class UlimitApp extends ConsumerStatefulWidget {
  const UlimitApp({super.key});

  @override
  ConsumerState<UlimitApp> createState() => _UlimitAppState();
}

class _UlimitAppState extends ConsumerState<UlimitApp> with WidgetsBindingObserver {
  UsageTracker? _tracker;
  bool _nativeSynced = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // System-UI Pause/Resume/End actions (from the Focus indicator
    // notification) route through the same FocusController used by the
    // in-app buttons.
    EnforcementChannel.setFocusActionHandler((action) async {
      await ref.read(focusIndicatorSyncProvider).handleAction(action);
    });

    // Pre-warm every tab's expensive providers at BOOT, not on first
    // visit. PageView builds tabs lazily, so without this the first tap
    // on Settings/Bedtime/Limits pays the cost of the permission channel
    // round-trips, the app catalog fetch (hundreds of icons over the
    // channel) and the weekly/engine aggregates — a multi-second freeze
    // mid-gesture on low-end devices. Warming during the launch frame
    // makes the first visit to ANY tab instant.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(allPermissionsProvider);
      ref.read(appsCatalogProvider);
      ref.read(ulimitSettingsProvider);
      ref.read(hideNavBarProvider);
      ref.read(themeModeProvider);
      ref.read(todayScreenTimeProvider);
      ref.read(todayUsageByPackageDebouncedProvider);
      ref.read(weeklyScreenTimeProvider);
      ref.read(restrictionDecisionsProvider);
      ref.read(permissionsOnboardingCompletedProvider);
      ref.read(focusIndicatorEnabledProvider);
      // Limits-tab data sources: the app_usage JOIN and the group
      // queries are resolved at boot so the first Limits visit never
      // pays their cold-start cost.
      ref.read(appLimitsProvider);
      ref.read(restrictionGroupsProvider);
      // Manual/internet/website rule sets feed Restrictions, Internet
      // and Notifications detail screens — warmed so those pushes are
      // instant too.
      ref.read(manualRestrictionsProvider);
      ref.read(internetBlocksProvider);
      ref.read(customWebsiteRulesProvider);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tracker?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-sync the native enforcement snapshot on every resume: the
    // accessibility service may have (re)started while the app was
    // away, and it must never run on a stale or missing snapshot.
    if (state == AppLifecycleState.resumed) {
      if (_nativeSynced) {
        ref.read(enforcementSyncProvider).push();
        ref.read(focusIndicatorSyncProvider).sync();
      }
    }
  }

  @override
  void didChangePlatformBrightness() {
    // System mode follows the OS: re-sync the static palette the
    // painters/icons read, then rebuild.
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    _tracker ??= UsageTracker(ref.read(databaseProvider))..start();

    // Persist "onboarding completed" as soon as every required
    // permission is granted — covers both the Continue-tap path and the
    // user granting everything and letting the watch below flip the
    // gate without ever touching Continue.
    ref.listen(requiredPermissionsGrantedProvider, (previous, next) {
      if (next && !(previous ?? false)) {
        ref.read(settingsControllerProvider).setPermissionsOnboardingCompleted(true);
      }
    });

    final permissionsGranted = ref.watch(requiredPermissionsGrantedProvider);
    final onboardingCompleted =
        ref.watch(permissionsOnboardingCompletedProvider).valueOrNull ?? false;
    final themeMode = _resolveThemeMode(ref.watch(themeModeProvider).valueOrNull ?? 'system');

    // Sync the static palette (CustomPainters, the accessibility-driven
    // overlay chrome and other non-Theme readers resolve colors from
    // AppColors, not Theme.of) BEFORE building, so even the first frame
    // of a newly selected appearance is consistent.
    AppColors.use(themeMode == ThemeMode.light ? Brightness.light : Brightness.dark);

    // The gate: until every required permission is granted, the app
    // shows nothing but the permissions screen — there's no route to
    // Home, Focus, or any control screen with the enforcement engine
    // half-wired, which would just be a UI that lies about what it's
    // doing. Two distinct MaterialApp branches (rather than swapping
    // `home` on one instance) keeps go_router's own Navigator fully
    // out of the picture until it's actually needed.
    //
    // Users who completed onboarding before (flag persisted in the DB)
    // get the compact re-enable screen instead of the full wizard:
    // Android resets accessibility / notification-listener grants on
    // EVERY app update, so a repeat of the 5-card onboarding every time
    // a new APK lands is not a "first launch".
    if (!permissionsGranted) {
      return MaterialApp(
        title: 'Ulimit',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeMode,
        home: onboardingCompleted
            ? PermissionsRecoveryScreen(onReEnabled: () {
                // no-op — the provider watch above handles the transition
                // the instant permissionsGranted flips true.
              })
            : PermissionsScreen(
                onAllGranted: () {
                  // Persist completion so future updates use the
                  // recovery screen rather than this wizard again.
                  ref.read(settingsControllerProvider).setPermissionsOnboardingCompleted(true);
                },
              ),
      );
    }

    // Once inside the app: keep the native enforcement snapshot in sync
    // with every policy change for the whole process lifetime.
    if (!_nativeSynced) {
      _nativeSynced = true;
      // Trigger lazily on first frame so DB streams are ready.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(enforcementSyncProvider).push();
        ref.read(focusIndicatorSyncProvider).sync();
      });
    }

    return MaterialApp.router(
      title: 'Ulimit',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      // Delegate wiring (not routerConfig) so our guarded
      // backButtonDispatcher sits between the system back press and
      // go_router, preventing the cold-start navigator null crash.
      routerDelegate: appRouter.routerDelegate,
      routeInformationProvider: appRouter.routeInformationProvider,
      routeInformationParser: appRouter.routeInformationParser,
      backButtonDispatcher: UlimitBackButtonDispatcher(appRouter),
    );
  }

  /// 'system' | 'dark' | 'white' → Flutter ThemeMode.
  ThemeMode _resolveThemeMode(String setting) {
    switch (setting) {
      case 'dark':
        return ThemeMode.dark;
      case 'white':
        return ThemeMode.light;
      default:
        return ThemeMode.system;
    }
  }
}
