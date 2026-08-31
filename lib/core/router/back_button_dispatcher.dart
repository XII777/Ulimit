import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// A [RootBackButtonDispatcher] that swallows system back events until
/// the router's root navigator is attached.
///
/// Rationale: go_router 14.x `GoRouterDelegate._findCurrentNavigator`
/// null-checks the shell navigator state with
/// `walker.navigatorKey.currentState!` (delegate.dart:114). Android can
/// dispatch a back event before the shell `Navigator` has mounted —
/// the cold-start race — and that unchecked null check crashes the app
/// with "Null check operator used on a null value".
///
/// Wiring uses the public delegate trio (routerDelegate /
/// routeInformationProvider / routeInformationParser) instead of
/// `routerConfig` precisely so this guard can sit between the platform
/// back event and go_router. Once the root navigator is attached, back
/// events flow through to the Router untouched.
class UlimitBackButtonDispatcher extends RootBackButtonDispatcher {
  UlimitBackButtonDispatcher(this._router);

  final GoRouter _router;

  bool get _navigatorMounted =>
      _router.routerDelegate.navigatorKey.currentState != null;

  @override
  Future<bool> didPopRoute() {
    if (!_navigatorMounted) {
      // Swallow: go_router's _findCurrentNavigator would null-check the
      // shell navigator and crash before the first frame is up.
      return Future<bool>.value(true);
    }
    return super.didPopRoute();
  }
}