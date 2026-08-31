import 'package:flutter/material.dart';

/// A number/string display where only the characters that actually
/// changed between updates animate — "475" → "476" rolls just the "5".
///
/// Uses AnimatedSwitcher's default single-child-swap behavior: the
/// previous child is evicted as soon as its transition finishes, so
/// overlapping ghosts can never accumulate. Each character slot has a
/// fixed height so the odometer slide can never grow the row vertically.
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
    final sameLength = previous != null && previous.length == current.length;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(current.length, (i) {
        final char = current[i];
        final changed = !sameLength || previous[i] != char;

        return SizedBox(
          height: (widget.style.fontSize ?? 14) * 1.5,
          child: ClipRect(
            child: AnimatedSwitcher(
              duration: widget.duration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final isNew = child.key == ValueKey('$char-$i-new');
                final slide = Tween<Offset>(
                  begin: isNew ? const Offset(0, 0.6) : Offset.zero,
                  end: isNew ? Offset.zero : const Offset(0, -0.6),
                ).animate(animation);
                return SlideTransition(
                  position: slide,
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: Text(
                char,
                key: changed ? ValueKey('$char-$i-new') : ValueKey('static-$i-$char'),
                style: widget.style,
              ),
            ),
          ),
        );
      }),
    );
  }
}
