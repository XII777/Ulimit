import 'package:flutter/material.dart';

/// A small, self-dismissing confirmation pill — "Streak continued",
/// "+10 Focus" — per the brief's "micro-achievement" spec: fade+slide
/// in, hold, fade+slide out, no modal, no celebration screen. Callers
/// control *when* it shows by changing [message] from null to a string;
/// this widget owns only the appear/hold/disappear animation.
class AchievementToast extends StatefulWidget {
  const AchievementToast({super.key, required this.message, required this.accentColor});

  final String? message;
  final Color accentColor;

  @override
  State<AchievementToast> createState() => _AchievementToastState();
}

class _AchievementToastState extends State<AchievementToast> {
  String? _displayed;

  @override
  void didUpdateWidget(AchievementToast old) {
    super.didUpdateWidget(old);
    if (widget.message != null && widget.message != old.message) {
      setState(() => _displayed = widget.message);
      Future.delayed(const Duration(milliseconds: 1600), () {
        if (mounted && _displayed == widget.message) setState(() => _displayed = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedSlide(
        offset: _displayed == null ? const Offset(0, -0.4) : Offset.zero,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: _displayed == null ? 0 : 1,
          duration: const Duration(milliseconds: 220),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1D25),
              borderRadius: BorderRadius.circular(100),
              border: Border.all(color: widget.accentColor.withOpacity(0.4)),
              boxShadow: [BoxShadow(color: widget.accentColor.withOpacity(0.25), blurRadius: 16)],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt_rounded, size: 13, color: widget.accentColor),
                const SizedBox(width: 6),
                Text(
                  _displayed ?? '',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: widget.accentColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
