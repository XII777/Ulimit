import 'package:rolling_text/rolling_text.dart';

/// Shared config for the rolling duration numbers.
///
/// Every digit rolls at the SAME TIME (`stagger: Duration.zero`) — no
/// one-by-one ripple — with a gentle spring and a soft odometer edge fade
/// so glyphs glide instead of hard-clipping. `direction: up` matches the
/// reference showcase.
const RollingTextOptions kCounterRollOptions = RollingTextOptions(
  direction: RollingDirection.up,
  stagger: Duration.zero,
  duration: Duration(milliseconds: 260),
  bounce: 0.2,
  fadeEdges: 0.15,
);

/// Horizontal gap between character slots for the counters (logical px).
/// Kept wide so digits/letters never touch or clip at the slot edge.
const double kCounterRollSpacing = 4.0;
