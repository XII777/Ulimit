import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rolling_text/rolling_text.dart';

import '../../core/router/app_router.dart';

/// The current top-level route path. [NavShell] publishes this on every
/// tab change so keep-alive tab screens can replay their heading
/// animation when they become the active tab — their `State` outlives the
/// switch, so a plain `initState` animation would only ever play once.
final currentRouteProvider = StateProvider<String>((ref) => Routes.home);

/// A staggered, direction-aware rolling heading (the `rolling_text`
/// package) used for screen titles. It rolls in when mounted and replays
/// every time [route] becomes the active route — the "change screen, the
/// title rolls" effect.
///
/// Leave [route] null for pushed detail screens, which mount fresh and
/// animate once on first appear.
class RollingTitle extends ConsumerStatefulWidget {
  const RollingTitle({super.key, required this.text, this.style, this.route});

  final String text;
  final TextStyle? style;

  /// This screen's route path, used to replay the roll on each switch.
  final String? route;

  @override
  ConsumerState<RollingTitle> createState() => _RollingTitleState();
}

class _RollingTitleState extends ConsumerState<RollingTitle> {
  int _generation = 0;
  bool _wasActive = false;

  @override
  Widget build(BuildContext context) {
    // Keep-alive tab screens outlive navigation, so we can't rely on
    // mounting; watch the active route and replay only when THIS screen
    // transitions into being the active one (never on deactivate — that
    // would re-roll off-screen and waste frames on a low-end device).
    final currentRoute = ref.watch(currentRouteProvider);
    final active = widget.route == null || currentRoute == widget.route;
    if (active && !_wasActive) _generation++;
    _wasActive = active;

    return RollingText(
      // New key on each replay (and on first mount) so the package
      // re-rolls even though [text] is unchanged.
      key: ValueKey('${widget.route ?? 'mount'}:$_generation'),
      text: widget.text,
      style: widget.style ?? Theme.of(context).textTheme.headlineSmall!,
      options: const RollingTextOptions(
        direction: RollingDirection.up,
        stagger: Duration(milliseconds: 40),
        bounce: 0.8,
      ),
    );
  }
}
