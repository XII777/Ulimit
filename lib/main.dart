import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

void main() {
  // No Firebase.init, no analytics SDK init, no remote-config fetch —
  // this app is local-first, so main() has nothing to await. Startup
  // is bounded by Flutter's own engine warm-up, not our code.
  runApp(const ProviderScope(child: UlimitApp()));
}

class UlimitApp extends StatelessWidget {
  const UlimitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Ulimit',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: appRouter,
    );
  }
}
