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
    this.duration = const Duration(milliseconds: 180),
  });

  final String text;
  final TextStyle style;
  final Duration duration;

  @override
  State<RollingNumber> createState() => _RollingNumberState();
}

class _RollingNumberState extends State<RollingNumber> {
  String? _previousText;

  // Cache the slot-height measurement: TextPainter.layout() costs a font
  // resolution pass and this widget rebuilds every SECOND on live
  // counters. The style (and its merged DefaultTextStyle) only changes
  // on theme/text-scale changes, so measure once and reuse.
  double? _cachedSlotHeight;
  TextStyle? _measuredStyle;
  TextScaler? _measuredScaler;

  @override
  void didUpdateWidget(RollingNumber old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _previousText = old.text;
    if (old.style != widget.style) _cachedSlotHeight = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Any inherited change (DefaultTextStyle, text scaler) invalidates.
    _cachedSlotHeight = null;
  }

  double _slotHeight(BuildContext context, TextScaler textScaler) {
    final cached = _cachedSlotHeight;
    if (cached != null && textScaler == _measuredScaler) return cached;

    final effectiveStyle = DefaultTextStyle.of(context).style.merge(widget.style);
    final painter = TextPainter(
      text: TextSpan(text: '0', style: effectiveStyle),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    _cachedSlotHeight = painter.height;
    _measuredScaler = textScaler;
    return painter.height;
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.text;
    final previous = _previousText;
    final sameLength = previous != null && previous.length == current.length;
    final textScaler = MediaQuery.textScalerOf(context);
    final slotHeight = _slotHeight(context, textScaler);

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
                final isStatic = child.key == ValueKey('static-$i-$char');
                // Roll distance in FRACTION OF SLOT HEIGHT. The old
                // 0.6 sent a digit 60% of its line box up/down on every
                // tick — a huge jump for a step from 9→0, reading as
                // vibration on 16px text. 0.12 (≈2.5px at 16px) is a
                // subtle odometer scroll that reads as motion, not
                // jitter, and settles visibly.
                const roll = 0.12;
                final begin = isNew
                    ? const Offset(0, roll)
                    : isStatic
                        ? Offset.zero
                        : Offset.zero;
                final end = isNew
                    ? Offset.zero
                    : isStatic
                        ? Offset.zero
                        : const Offset(0, -roll);
                final slide = Tween<Offset>(begin: begin, end: end).animate(animation);
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