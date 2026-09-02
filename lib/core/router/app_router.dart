import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/widgets/app_sheet.dart';
import '../../shared/widgets/nav_shell.dart';
import '../../features/home/home_screen.dart';
import '../../features/focus/focus_screen.dart';
import '../../features/focus/focus_history_screen.dart';
import '../../features/limits/limits_screen.dart';
import '../../features/restrictions/restrictions_screen.dart';
import '../../features/internet/internet_sites_screen.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/bedtime/bedtime_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/stats/app_stats_screen.dart';
import '../../features/stats/screen_time_screen.dart';
import '../../features/parental/parental_screen.dart';
import 'morph_transition.dart';

/// Route paths as constants — avoids magic strings scattered across
/// 15+ screens and makes renames a one-line change.
abstract final class Routes {
  static const home = '/';
  static const focus = '/focus';
  static const limits = '/limits';
  static const restrictions = '/restrictions';
  static const internet = '/internet';
  static const notifications = '/notifications';
  static const bedtime = '/bedtime';
  static const settings = '/settings';
  static const parental = '/parental';
  static const focusHistory = '/focus-history';
  static const screenTime = '/screen-time';
  static const appStats = '/app-stats';

  // Tab-navigation direction state for the swipe transition. NavShell
  // writes these on every tab change; _tabRoute's transition reads them.
  static int lastTabIndex = 0;
  static double tabDirection = 1.0;
}

final appRouter = GoRouter(
  initialLocation: Routes.home,
  // Lets the shell hide the floating pill whenever any route (sheet,
  // dialog, detail screen) is pushed above it.
  observers: [AppUiObserver()],
  routes: [
    // ShellRoute keeps the floating nav bar mounted across tab switches
    // instead of rebuilding it (and its icons/animations) on every nav —
    // this is the single biggest jank source in bottom-nav apps that get
    // it wrong.
    ShellRoute(
      builder: (context, state, child) => NavShell(child: child),
      routes: [
        _tabRoute(Routes.home,  HomeScreen()),
        _tabRoute(Routes.focus,  FocusScreen()),
        _tabRoute(Routes.limits,  LimitsScreen()),
        _tabRoute(Routes.bedtime,  BedtimeScreen()),
        _tabRoute(Routes.settings,  SettingsScreen()),
      ],
    ),
    // Detail screens push OUTSIDE the shell so the nav bar correctly
    // disappears rather than fighting a full-screen modal.
    _detailRoute(Routes.restrictions,  RestrictionsScreen()),
    _detailRoute(Routes.focusHistory,  FocusHistoryScreen()),
    _detailRoute(Routes.screenTime,  ScreenTimeScreen()),
    _detailRouteWithPackage(Routes.appStats, (pkg) => AppStatsScreen(packageName: pkg)),
    _detailRoute(Routes.internet,  InternetSitesScreen()),
    _detailRoute(Routes.notifications,  NotificationsScreen()),
    _detailRoute(Routes.parental,  ParentalScreen()),
  ],
);

GoRoute _tabRoute(String path, Widget child) {
  return GoRoute(
    path: path,
    pageBuilder: (context, state) => CustomTransitionPage(
      key: state.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      transitionsBuilder: (context, animation, secondaryAnimation, page) =>
          tabSlide(page, animation, Routes.tabDirection),
    ),
  );
}

GoRoute _detailRoute(String path, Widget child) {
  return GoRoute(
    path: path,
    pageBuilder: (context, state) => CustomTransitionPage(
      key: state.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      // Same fade+scale curve as MorphPage (see morph_transition.dart) —
      // duplicated inline rather than reused because MorphPage is a
      // PageRouteBuilder for imperative Navigator.push, not a go_router
      // Page; CustomTransitionPage is go_router's equivalent shape.
      // SheetZoom gives pushed screens the same iOS background-zoom
      // reaction when a bottom sheet opens on top of them.
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.97, end: 1.0).animate(curved),
            child: SheetZoom(child: child),
          ),
        );
      },
    ),
  );
}

/// [Routes.appStats]-style detail route whose widget needs the package
/// name from the `?pkg=` query param. The builder receives the package
/// (or '' when absent).
GoRoute _detailRouteWithPackage(String path, Widget Function(String pkg) builder) {
  return GoRoute(
    path: path,
    pageBuilder: (context, state) => CustomTransitionPage(
      key: state.pageKey,
      child: builder(state.uri.queryParameters['pkg'] ?? ''),
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.97, end: 1.0).animate(curved),
            child: SheetZoom(child: child),
          ),
        );
      },
    ),
  );
}
