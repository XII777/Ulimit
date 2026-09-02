import 'package:flutter/material.dart';
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

/// A rolling duration number with the app's counter config.
///
/// Pins [TextScaler] to noScaling: the package measures each character
/// cell from the RAW font metrics (height: 1.0, unscaled) but renders the
/// glyphs with the ambient MediaQuery text scaler — so on a device with an
/// enlarged system font-scale the glyphs are drawn taller than the cell
/// and get clipped top/bottom (the "rounded/cut" look). Forcing the same
/// (unscaled) scale at render time makes the measured cell and the drawn
/// glyph agree, removing the clip.
class RollingCounter extends StatelessWidget {
  const RollingCounter({super.key, required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(textScaler: TextScaler.noScaling),
      child: RollingText(
        text: text,
        spacing: kCounterRollSpacing,
        style: style,
        options: kCounterRollOptions,
      ),
    );
  }
}
