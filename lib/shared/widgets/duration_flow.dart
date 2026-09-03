import 'package:flutter/widgets.dart';
import 'package:number_flow_flutter/number_flow_flutter.dart';

/// An animated duration display (odometer wheels, from the
/// `number_flow_flutter` package).
///
/// - **Matching typeface**: the caller's style merges over the inherited
///   default text style (same as a plain [Text]), so the rolling digits
///   render in the app font, not the platform default.
/// - **No cropping**: the package sizes every glyph from Flutter's real
///   text metrics (current text scaler included), so digits and separators
///   are always fully visible; `mask: true` only softens the wheel edges.
/// - **No extra breathing space**: default wheel spacing and tabular digit
///   widths (uniform, no horizontal shift while rolling).
/// - **iOS-smooth**: `NumberFlowSpring.ios` — springy roll with overshoot
///   and velocity hand-off when values change quickly.
/// - **Auto-fit**: `FittedBox(scaleDown)` guarantees the whole value stays
///   inside its container; it only ever shrinks, never grows.
///
/// This is the app-wide standard for every displayed duration or
/// countdown — see FlowNumber for rolling integers.
class DurationFlow extends StatelessWidget {
  const DurationFlow(
    this.duration, {
    super.key,
    this.style,
    this.showSeconds = true,
  });

  final Duration duration;
  final TextStyle? style;

  /// Omits the seconds wheels for coarse displays ("2h 18m") — used
  /// where second-level precision is noise (limits, pickers).
  final bool showSeconds;

  @override
  Widget build(BuildContext context) {
    final resolved = DefaultTextStyle.of(context).style.merge(style);
    return TimeFlow.duration(
      duration,
      style: resolved,
      showSeconds: showSeconds,
      spring: NumberFlowSpring.ios,
      tabularNums: true,
    );
  }
}

/// A rolling integer — the same odometer treatment as [DurationFlow]
/// applied to plain numbers (counters, averages, streaks). Animates
/// digit-by-digit with the iOS spring whenever [value] changes.
class FlowNumber extends StatelessWidget {
  const FlowNumber(this.value, {super.key, this.style, this.suffix});

  final int value;
  final TextStyle? style;

  /// Optional trailing text rendered as part of the flow (e.g. "m",
  /// "/day") so it moves with the wheels instead of jumping.
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final resolved = DefaultTextStyle.of(context).style.merge(style);
    return NumberFlow(
      value: value,
      suffix: suffix,
      style: resolved,
      spring: NumberFlowSpring.ios,
      tabularNums: true,
    );
  }
}

/// A rolling duration with a plain-text tail: "2h 18m left", "1h / 2h".
/// Pairs [DurationFlow] with static [Text]s in a tight row; scale-down
/// guarantees no overflow at large text scalers.
class FlowDurationText extends StatelessWidget {
  const FlowDurationText(
    this.duration, {
    super.key,
    required this.suffix,
    this.style,
    this.showSeconds = false,
    this.suffixStyle,
  });

  final Duration duration;
  final String suffix;
  final TextStyle? style;
  final TextStyle? suffixStyle;
  final bool showSeconds;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DurationFlow(duration, style: style, showSeconds: showSeconds),
          Text(suffix, style: suffixStyle),
        ],
      ),
    );
  }
}
