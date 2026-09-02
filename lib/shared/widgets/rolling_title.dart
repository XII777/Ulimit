import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rolling_text/rolling_text.dart';

import '../../core/router/app_router.dart';

/// The current top-level route path. [NavShell] publishes this on every
/// tab change so keep-alive tab screens can replay their heading
/// animation when they become the active tab — their `State` outlives the
/// switch, so a plain `initState` animation would only ever play once.
final currentRouteProvider = StateProvider<String>((ref) => Routes.home);

/// The shared rolling animation config across the app.
///
/// Tuned for butter-smooth, non-clipping rolls:
///  - `bounce: 0.2` — a gentle spring: no overshoot, so a per-second live
///    counter glides instead of vibrating (the default 0.6/0.8 looks
///    jittery on timers and overshoots the cell, clipping the glyph).
///  - `fadeEdges: 0.15` — fades the top/bottom of each character cell so
///    the roll reads as a smooth odometer instead of a hard clip.
///  - `stagger: 30ms` + `duration: 260ms` — the ripple settles well
///    inside a 1-second tick, so consecutive updates never interrupt.
const RollingTextOptions kRollingTextOptions = RollingTextOptions(
  direction: RollingDirection.up,
  stagger: Duration(milliseconds: 30),
  duration: Duration(milliseconds: 260),
  bounce: 0.2,
  fadeEdges: 0.15,
);

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
      // re-rolls even though [text] is unchanged. `spacing` keeps glyphs
      // from touching/clipping at the slot edge, and the spring config
      // matches the reference showcase (up, 40ms stagger, 0.8 bounce).
      key: ValueKey('${widget.route ?? 'mount'}:$_generation'),
      text: widget.text,
      spacing: 2.0,
      style: widget.style ?? Theme.of(context).textTheme.headlineSmall!,
      options: kRollingTextOptions,
    );
  }
}
