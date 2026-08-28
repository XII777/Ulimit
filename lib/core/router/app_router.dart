import 'package:go_router/go_router.dart';
import '../../shared/widgets/nav_shell.dart';
import '../../features/home/home_screen.dart';
import '../../features/focus/focus_screen.dart';
import '../../features/limits/limits_screen.dart';
import '../../features/bedtime/bedtime_screen.dart';
import '../../features/settings/settings_screen.dart';
import 'morph_transition.dart';

/// Route paths as constants — avoids magic strings scattered across
/// 15+ screens and makes renames a one-line change.
abstract final class Routes {
  static const home = '/';
  static const focus = '/focus';
  static const limits = '/limits';
  static const bedtime = '/bedtime';
  static const settings = '/settings';
}

final appRouter = GoRouter(
  initialLocation: Routes.home,
  routes: [
    // ShellRoute keeps the floating nav bar mounted across tab switches
    // instead of rebuilding it (and its icons/animations) on every nav —
    // this is the single biggest jank source in bottom-nav apps that get
    // it wrong.
    ShellRoute(
      builder: (context, state, child) => NavShell(child: child),
      routes: [
        GoRoute(
          path: Routes.home,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const HomeScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.focus,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const FocusScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.limits,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const LimitsScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.bedtime,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const BedtimeScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.settings,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const SettingsScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
      ],
    ),
    // Detail screens (App Limits detail, Internet & Sites, blocking
    // overlay, etc.) push OUTSIDE the shell using MorphPage so the nav
    // bar correctly disappears rather than fighting a full-screen modal.
  ],
);
