import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:ulimit/core/router/back_button_dispatcher.dart';

void main() {
  testWidgets('back event before navigator mounts is swallowed, not forwarded',
      (tester) async {
    var pops = 0;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const SizedBox.shrink(),
        ),
      ],
    );
    // Add a callback that would fire if didPopRoute is forwarded.
    final dispatcher = UlimitBackButtonDispatcher(router);

    // Navigators are not mounted yet (nothing pumped) — a back event must
    // be swallowed (returns true = handled), never reaching go_router.
    final handled = await dispatcher.didPopRoute();
    expect(handled, isTrue);
    expect(pops, 0);

    router.dispose();
  });

  testWidgets('back event after navigator mounts is forwarded to go_router',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => TextButton(
            onPressed: () => context.go('/'),
            child: const Text('home'),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        routerDelegate: router.routerDelegate,
        routeInformationProvider: router.routeInformationProvider,
        routeInformationParser: router.routeInformationParser,
      ),
    );
    await tester.pumpAndSettle();

    final dispatcher = UlimitBackButtonDispatcher(router);
    // Delegate wiring: the Router registers its callback on this
    // dispatcher — forward via super so the delegate sees it.
    final handled = await dispatcher.didPopRoute();
    expect(handled, isFalse);

    router.dispose();
  });
}
