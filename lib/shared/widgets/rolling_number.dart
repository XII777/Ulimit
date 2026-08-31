import 'package:flutter/material.dart';

/// A number/string display where only the characters that actually
/// changed between updates animate — "475" → "476" rolls just the "5".
///
/// Each character slot sizes to the actual rendered line height of the
/// text (measured via TextPainter) so the ClipRect never clips the
/// glyphs — the old fontSize * 1.5 heuristic was too short for the
/// Inter font at 16px bold, cutting off the tops and bottoms of digits.
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

    // Measure the actual rendered line height of one glyph in the
    // given style (Inter bold 16px + tabularFigures, etc.). The old
    // fontSize * 1.5 heuristic was too short for Inter's metrics,
    // causing ClipRect to cut off the top and bottom of digits.
    //
    // The style must be merged with the ambient DefaultTextStyle —
    // exactly like the Text widget does at render time — so the
    // measurement reflects the real font (Inter from the app theme),
    // not just the explicit fontSize/weight passed in.
    final textScaler = MediaQuery.textScalerOf(context);
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(widget.style);
    final painter = TextPainter(
      text: TextSpan(text: '0', style: effectiveStyle),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    final slotHeight = painter.height;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(current.length, (i) {
        final char = current[i];
        final changed = !sameLength || previous[i] != char;

        return SizedBox(
          height: slotHeight,
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