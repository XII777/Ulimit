import 'package:flutter/widgets.dart';
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

/// A [RollingText] duration counter that auto-shrinks to fit whatever
/// width its container gives it — and only ever shrinks, never grows.
///
/// The counters on Home sit in half-width `PremiumCard`s sized for a
/// typical value. A long one ("8h 10m 0s") is wider than what the card
/// reserves and would overflow the card's right edge; a short one
/// ("0s") must NOT be blown up to fill the space, since that reads as
/// broken/jumpy against its neighboring card as the value changes
/// length tick to tick. `BoxFit.scaleDown` gives exactly that: it
/// scales the rolling text down when it doesn't fit, and leaves it at
/// its natural size otherwise — it never scales past 1.0.
///
/// It also pins [TextScaler] to noScaling: the package measures each
/// character cell from the RAW font metrics (unscaled) but renders the
/// glyphs with the ambient MediaQuery text scaler, so on a device with an
/// enlarged system font-scale every glyph is drawn wider AND taller than
/// its cell — the next character covers its right side and the cell clip
/// cuts the top/bottom. Forcing the same (unscaled) scale at render time
/// makes the measured cell and the drawn glyph agree.
class RollingCounter extends StatelessWidget {
  const RollingCounter({
    super.key,
    required this.text,
    required this.style,
    this.spacing = kCounterRollSpacing,
    this.options = kCounterRollOptions,
    this.alignment = Alignment.centerLeft,
  });

  /// The formatted duration text, e.g. via `formatDurationHMS`.
  final String text;
  final TextStyle style;
  final double spacing;
  final RollingTextOptions options;

  /// Where the (possibly shrunk) counter sits within the space it's
  /// given. Left-aligned by default so a shrinking counter doesn't
  /// visually drift toward the card's center as it gets shorter.
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(textScaler: TextScaler.noScaling),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignment,
        child: RollingText(
          text: text,
          spacing: spacing,
          options: options,
          style: style,
        ),
      ),
    );
  }
}
