import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';
import '../../shared/widgets/limit_ring.dart';

class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  static const _total = Duration(minutes: 25);
  Duration _remaining = _total;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // A 1-second periodic timer is cheap — the ring's own repaint is
    // gated by shouldRepaint, so this doesn't cost more than one
    // CustomPainter.paint() per second, not per frame.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_remaining.inSeconds <= 0) {
        _ticker?.cancel();
        return;
      }
      setState(() => _remaining -= const Duration(seconds: 1));
    });
  }

  @override
  void dispose() {
    _ticker?.cancel(); // leaking this timer is the #1 cause of
    // "why does my app get slower the longer it's open" bug reports
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = 1 - (_remaining.inSeconds / _total.inSeconds);

    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.6),
          radius: 1.0,
          colors: [Color(0xFF191533), AppColors.bg],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            const _InvincibleChip(),
            const Spacer(),
            LimitRing(
              progress: progress,
              size: 220,
              strokeWidth: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_format(_remaining), style: const TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    fontSize: 38,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  )),
                  const SizedBox(height: 6),
                  Text('Deep Work · remaining', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => _confirmEndEarly(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(14),
                    backgroundColor: AppColors.surface2,
                    side: const BorderSide(color: AppColors.stroke),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: const Text('End session early', style: TextStyle(color: AppColors.inkDim)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _format(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _confirmEndEarly(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (_) => const SizedBox(height: 160, child: Center(child: Text('Confirm sheet — wire to session provider'))),
    );
  }
}

class _InvincibleChip extends StatelessWidget {
  const _InvincibleChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.14),
        border: Border.all(color: AppColors.accent.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.lock_rounded, size: 12, color: AppColors.accentSoft),
          SizedBox(width: 6),
          Text('Invincible mode on', style: TextStyle(fontSize: 11.5, color: AppColors.accentSoft)),
        ],
      ),
    );
  }
}
