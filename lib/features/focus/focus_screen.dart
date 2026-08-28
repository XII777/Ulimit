import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/providers.dart';
import '../../shared/widgets/limit_ring.dart';

class FocusScreen extends ConsumerStatefulWidget {
  const FocusScreen({super.key});

  @override
  ConsumerState<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends ConsumerState<FocusScreen> {
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
    final todaysSessions = ref.watch(todaysCompletedSessionsProvider);

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
            const SizedBox(height: 20),
            const _LockNote(),
            const Spacer(),
            todaysSessions.when(
              data: (completed) => _TodaysSessions(completed: completed),
              loading: () => const _TodaysSessions(completed: 0),
              error: (_, __) => const _TodaysSessions(completed: 0),
            ),
            const SizedBox(height: 20),
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
        children: [
          Icon(Icons.lock_rounded, size: 12, color: AppColors.accentSoft),
          SizedBox(width: 6),
          Text('Invincible mode on', style: TextStyle(fontSize: 11.5, color: AppColors.accentSoft)),
        ],
      ),
    );
  }
}

/// "12 apps paused · DND on" — reinforces what invincible mode is
/// actually doing while the ring runs, so the state isn't only
/// communicated once at the top of the screen.
///
/// Still a static string: it describes invincible mode's *fixed*
/// behavior (which apps get paused is a global setting, not per-session
/// data), not a per-session metric that needs its own provider.
class _LockNote extends StatelessWidget {
  const _LockNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.notifications_off_rounded, size: 13, color: AppColors.inkFaint),
        const SizedBox(width: 6),
        Text('12 apps paused · DND on', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5)),
      ],
    );
  }
}

class _TodaysSessions extends StatelessWidget {
  const _TodaysSessions({required this.completed});
  final int completed;
  static const _total = 3;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          "TODAY'S SESSIONS",
          style: Theme.of(context).textTheme.labelSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _total; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _SessionDot(state: i < completed
                  ? _SessionState.done
                  : i == completed
                      ? _SessionState.active
                      : _SessionState.empty),
            ],
          ],
        ),
      ],
    );
  }
}

enum _SessionState { done, active, empty }

class _SessionDot extends StatelessWidget {
  const _SessionDot({required this.state});
  final _SessionState state;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case _SessionState.active:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.accent, AppColors.calm],
            ),
            border: Border.all(color: AppColors.accent, width: 3),
          ),
        );
      case _SessionState.done:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.accent.withOpacity(0.25),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.accent),
          ),
          child: const Icon(Icons.check_rounded, size: 16, color: AppColors.accentSoft),
        );
      case _SessionState.empty:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.stroke),
          ),
        );
    }
  }
}
