import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// A [RootBackButtonDispatcher] that swallows system back events until
/// every navigator go_router's `_findCurrentNavigator` will deref is
/// actually mounted.
///
/// Rationale: go_router 14.x `GoRouterDelegate._findCurrentNavigator`
/// null-checks the SHELL navigator state with
/// `walker.navigatorKey.currentState!` (delegate.dart:114) while walking
/// the current match chain. Android can dispatch a back event during
/// the cold-start window — root navigator mounted, shell route's
/// navigator not yet — and that unchecked null check crashes the app
/// with "Null check operator used on a null value".
///
/// The guard walks the SAME match chain go_router walks
/// (`currentConfiguration.matches`, last element first) and only
/// forwards when every [ShellRouteMatch]'s navigator has an attached
/// state. It cannot race: the check is done at dispatch time, after
/// which the mounts are a durable fact for the current configuration.
///
/// Wiring uses the public delegate trio (routerDelegate /
/// routeInformationProvider / routeInformationParser) instead of
/// `routerConfig` so this guard sits between the platform back event
/// and go_router.
class UlimitBackButtonDispatcher extends RootBackButtonDispatcher {
  UlimitBackButtonDispatcher(this._router);

  final GoRouter _router;

  /// True only when every navigator that go_router's popRoute would
  /// dereference has a mounted [NavigatorState] right now.
  bool get _navigatorsReady {
    final delegate = _router.routerDelegate;

    // Root navigator first — the common cold-start case.
    if (delegate.navigatorKey.currentState == null) {
      return false;
    }

    // Mirror go_router's `_findCurrentNavigator` walk: the last match
    // may be (or nest) ShellRouteMatch(es); each needs its navigator
    // state or the delegate's null check will crash on forward.
    RouteMatchBase walker = delegate.currentConfiguration.matches.last;
    while (walker is ShellRouteMatch) {
      if (walker.navigatorKey.currentState == null) {
        return false;
      }
      walker = walker.matches.last;
    }
    return true;
  }

  @override
  Future<bool> didPopRoute() {
    if (!_navigatorsReady) {
      // Swallow: go_router's _findCurrentNavigator would null-check the
      // (missing) shell navigator and crash before the frame is up.
      return Future<bool>.value(true);
    }
    return super.didPopRoute();
  }
}
