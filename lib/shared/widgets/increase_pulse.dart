import 'package:flutter/material.dart';

/// Wraps [child] and briefly scales + glows it whenever [value] increases
/// versus the last build — used for the streak flame icon. A single
/// AnimatedContainer + AnimatedScale pair, no continuous ticker running
/// in the background when idle, so it costs nothing between streak
/// increments.
class IncreasePulse extends StatefulWidget {
  const IncreasePulse({
    super.key,
    required this.value,
    required this.child,
    this.glowColor = const Color(0xFFAEFF00),
  });

  final int value;
  final Widget child;
  final Color glowColor;

  @override
  State<IncreasePulse> createState() => _IncreasePulseState();
}

class _IncreasePulseState extends State<IncreasePulse> {
  bool _pulsing = false;
  int? _lastValue;

  @override
  void didUpdateWidget(IncreasePulse old) {
    super.didUpdateWidget(old);
    if (_lastValue != null && widget.value > _lastValue!) {
      _firePulse();
    }
    _lastValue = widget.value;
  }

  @override
  void initState() {
    super.initState();
    _lastValue = widget.value;
  }

  void _firePulse() {
    setState(() => _pulsing = true);
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _pulsing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pulsing ? 1.25 : 1.0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: _pulsing
              ? [BoxShadow(color: widget.glowColor.withOpacity(0.55), blurRadius: 14, spreadRadius: 2)]
              : const [],
        ),
        child: widget.child,
      ),
    );
  }
}
