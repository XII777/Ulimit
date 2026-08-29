import 'package:flutter/material.dart';

/// A number/string display where only the characters that actually
/// changed between updates animate — "475" → "476" rolls just the "5",
/// not the whole string. Built as a plain AnimatedSwitcher-per-character
/// rather than a hand-tracked continuous-scroll odometer: it's far
/// cheaper (no per-frame drag/velocity math, no extra ticker beyond
/// what AnimatedSwitcher already uses), and for values that update at
/// most a few times a minute the crossfade+slide reads as a genuine
/// "roll" without the performance risk of a bespoke scroll physics
/// implementation.
class RollingNumber extends StatefulWidget {
  const RollingNumber({
    super.key,
    required this.text,
    required this.style,
    this.duration = const Duration(milliseconds: 320),
  });

  final String text;
  final TextStyle style;
  final Duration duration;

  @override
  State<RollingNumber> createState() => _RollingNumberState();
}

class _RollingNumberState extends State<RollingNumber> {
  String? _previousText;

  @override
  void didUpdateWidget(RollingNumber old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _previousText = old.text;
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.text;
    final previous = _previousText;

    // Character-by-character diff against the previous value. Different
    // lengths (e.g. "9" -> "10") fall back to animating the whole
    // string — a digit-by-digit diff across a length change would need
    // right-alignment/carry logic disproportionate to how rarely this
    // app's numbers cross a digit-count boundary.
    final sameLength = previous != null && previous.length == current.length;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(current.length, (i) {
        final char = current[i];
        final changed = !sameLength || previous[i] != char;

        return ClipRect(
          child: AnimatedSwitcher(
            duration: widget.duration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              final slideIn = Tween<Offset>(
                begin: const Offset(0, 0.6),
                end: Offset.zero,
              ).animate(animation);
              final slideOut = Tween<Offset>(
                begin: Offset.zero,
                end: const Offset(0, -0.6),
              ).animate(animation);
              // Outgoing digit slides up+fades, incoming slides in from
              // below+fades — the classic odometer look, per-character.
              return ClipRect(
                child: SlideTransition(
                  position: child.key == ValueKey('$char-$i-new') ? slideIn : slideOut,
                  child: FadeTransition(opacity: animation, child: child),
                ),
              );
            },
            child: Text(
              char,
              key: changed ? ValueKey('$char-$i-new') : ValueKey('static-$i-$char'),
              style: widget.style,
            ),
          ),
        );
      }),
    );
  }
}
