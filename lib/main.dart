import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/crash/crash_collector.dart';
import 'core/native/enforcement_channel.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/tokens.dart';
import 'data/focus_indicator.dart';
import 'data/permissions_providers.dart';
import 'data/providers.dart';
import 'data/restriction_providers.dart';
import 'data/usage_tracker.dart';
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

    final permissionsGranted = ref.watch(requiredPermissionsGrantedProvider);
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
    if (!permissionsGranted) {
      return MaterialApp(
        title: 'Ulimit',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeMode,
        home: PermissionsScreen(
          onAllGranted: () {}, // no-op — the provider watch above
          // handles the transition the instant permissionsGranted flips
          // true; see requiredPermissionsGrantedProvider's doc comment.
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
      routerConfig: appRouter,
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
