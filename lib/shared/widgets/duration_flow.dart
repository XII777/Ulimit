import 'package:flutter/widgets.dart';
import 'package:number_flow_flutter/number_flow_flutter.dart';

/// An animated duration display (odometer wheels, from the
/// `number_flow_flutter` package).
///
/// - **No cropping**: the package sizes every glyph from Flutter's real
///   text metrics (current text scaler included), so digits and separators
///   are always fully visible; `mask: true` only softens the wheel edges.
/// - **No extra breathing space**: default wheel spacing and tabular digit
///   widths (uniform, no horizontal shift while rolling).
/// - **iOS-smooth**: `NumberFlowSpring.ios` — springy roll with overshoot
///   and velocity hand-off when values change quickly.
/// - **Auto-fit**: `FittedBox(scaleDown)` guarantees the whole value stays
///   inside its container; it only ever shrinks, never grows.
class DurationFlow extends StatelessWidget {
  const DurationFlow({super.key, required this.duration, this.style});

  final Duration duration;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: TimeFlow.duration(
        duration,
        style: style,
        spring: NumberFlowSpring.ios,
        tabularNums: true,
      ),
    );
  }
}
