import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diagnostics_log.dart';
import '../../core/engine/restriction_engine.dart';
import '../../core/icons/app_icons.dart';
import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/doomscroll_providers.dart';
import '../../data/focus_indicator.dart';
import '../../data/focus_providers.dart';
import '../../data/permissions_providers.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../shared/widgets/spring_scroll.dart';

/// System Diagnostics: a live health report of every subsystem —
/// each check rendered as working (✓) / broken (✕) / pending (–) —
/// plus a rolling event log recording what actually happened, when.
///
/// Purpose: when "blocking doesn't work" the user can see WHICH layer
/// is failing instead of guessing — accessibility connected? snapshot
/// pushed? engine enforcing? feed detector active?
class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Re-render on the evaluation tick so expiry/push states refresh
    // without manual interaction.
    ref.watch(evaluationTickProvider);
    final checks = _buildChecks(context, ref);
    final working = checks.where((c) => c.state == _CheckState.ok).length;
    final failing = checks.where((c) => c.state == _CheckState.fail).length;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: AppIcon(AppIconName.back, size: 15, color: AppColors.inkDim),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Diagnostics',
                            style: TextStyle(
                                fontSize: AppText.headline,
                                fontWeight: FontWeight.w600,
                                color: AppColors.ink)),
                        Text('$working working · $failing failing · everything else pending',
                            style:
                                TextStyle(fontSize: AppText.caption, color: AppColors.inkDim)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                physics: springScrollPhysics,
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                children: [
                  _CheckCard(checks: checks),
                  const SizedBox(height: 16),
                  _EventLogCard(),
                  const SizedBox(height: 12),
                  Text(
                    'Checks are evaluated live — open this screen right after '
                    'reproducing a problem and the first failing check is the '
                    'broken layer. The event log records the last ~5 minutes of '
                    'activity.',
                    style: TextStyle(fontSize: 10.5, height: 1.5, color: AppColors.inkFaint),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<_Check> _buildChecks(BuildContext context, WidgetRef ref) {
    final checks = <_Check>[];

    // --- Permissions: the on/off switches every feature needs ---------
    final permissions = ref.watch(allPermissionsProvider);
    const needed = {
      PermissionKind.accessibility: 'Accessibility — instant detection + ejects',
      PermissionKind.vpn: 'VPN — internet & website blocking',
      PermissionKind.deviceAdmin: 'Device admin — tamper protection',
      PermissionKind.notificationListener: 'Notification access — quiet mode',
      PermissionKind.usageAccess: 'Usage access — accurate screen time',
      PermissionKind.overlayPermission: 'Display over apps — fallback blocking',
    };
    for (final p in permissions) {
      final label = needed[p.kind];
      if (label == null) continue; // biometric is a capability, not a check
      checks.add(_Check(
        label: label,
        state: p.granted ? _CheckState.ok : _CheckState.fail,
        detail: p.granted ? 'Granted' : 'Not granted — blocking layers that need it are off',
      ));
    }

    // --- Enforcement chain: Dart → native → engine --------------------
    final decisions = ref.watch(restrictionDecisionsProvider);
    final activePolicies = decisions.values.where((d) => d.appBlocked).length;
    checks.add(_Check(
      label: 'Policy engine — $activePolicies package(s) currently blocked',
      state: _CheckState.ok, // it runs; emptiness is a state, not a failure
      detail: activePolicies == 0
          ? 'No active restriction right now (nothing to enforce)'
          : 'Engine resolves limits, groups, focus & bedtime live',
    ));

    final lastPush = EnforcementSync.lastPushSummary;
    final pushError = EnforcementSync.lastPushError;
    final pushed = lastPush.startsWith('pushed');
    checks.add(_Check(
      label: 'Native policy sync — Dart → Android snapshot',
      state: pushError != null
          ? _CheckState.fail
          : pushed
              ? _CheckState.ok
              : _CheckState.pending,
      detail: pushError ?? lastPush,
    ));

    // --- Focus & doomscroll -------------------------------------------
    final focus = ref.watch(activeFocusSessionProvider).valueOrNull;
    checks.add(_Check(
      label: focus == null
          ? 'Focus session — none running'
          : 'Focus session — "${focus.label}" running',
      state: _CheckState.ok,
      detail: focus == null
          ? 'Start one from the Focus tab'
          : focus.pausedAt != null
              ? 'Paused'
              : 'Enforcement active until it ends',
    ));

    final doomRules = ref.watch(doomscrollRulesProvider).valueOrNull ?? const [];
    final managed = doomRules.where((r) => r.enabled).length;
    checks.add(_Check(
      label: 'Doomscroll — $managed platform(s) managed',
      state: managed > 0 ? _CheckState.ok : _CheckState.pending,
      detail: managed > 0
          ? 'Feed surfaces ejected in section apps; feed-native apps budgeted'
          : 'No doomscroll blocking configured',
    ));
    final doomOpens = ref.watch(doomscrollTodayTotalProvider);
    checks.add(_Check(
      label: 'Feed-open counting — $doomOpens today',
      state: _CheckState.ok,
      detail: 'Reels/Shorts/For-You surfaces detected by accessibility',
    ));

    // --- Focus indicator (foreground service) --------------------------
    final indicatorEnabled =
        ref.watch(focusIndicatorEnabledProvider).valueOrNull ?? true;
    checks.add(_Check(
      label: 'Focus indicator (status-bar chip)',
      state: focus == null
          ? _CheckState.pending
          : indicatorEnabled
              ? _CheckState.ok
              : _CheckState.fail,
      detail: focus == null
          ? 'Idle — no session'
          : indicatorEnabled
              ? 'Enabled — shows the session countdown in the status bar'
              : 'A session is running but the indicator setting is off',
    ));

    // --- Usage history --------------------------------------------------
    final todaySeconds = ref.watch(liveFocusSecondsTodayProvider).valueOrNull ?? 0;
    checks.add(_Check(
      label: 'Usage tracking — ${formatDurationShort(Duration(seconds: todaySeconds))} today',
      state: _CheckState.ok,
      detail: 'Foreground events bridge into the local database',
    ));

    return checks;
  }
}

// ---------------------------------------------------------------------------
// Checks card
// ---------------------------------------------------------------------------

enum _CheckState { ok, fail, pending }

class _Check {
  const _Check({required this.label, required this.state, this.detail});

  final String label;
  final _CheckState state;
  final String? detail;
}

class _CheckCard extends StatelessWidget {
  const _CheckCard({required this.checks});

  final List<_Check> checks;

  @override
  Widget build(BuildContext context) {
    // Failing checks sort to the top — the broken layer is the point.
    final sorted = [...checks]
      ..sort((a, b) => a.state.index.compareTo(b.state.index));

    return PremiumCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(AppIconName.shield, size: 14, color: AppColors.inkDim),
              const SizedBox(width: 7),
              Expanded(
                child: Text('SYSTEM HEALTH',
                    style: TextStyle(
                        fontSize: AppText.overline,
                        color: AppColors.inkDim,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final c in sorted)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 18,
                    child: switch (c.state) {
                      _CheckState.ok =>
                        AppIcon(AppIconName.check, size: 13, color: AppColors.ink),
                      _CheckState.fail =>
                        AppIcon(AppIconName.close, size: 13, color: AppColors.inkDim),
                      _CheckState.pending =>
                        Text('–', style: TextStyle(fontSize: 12, color: AppColors.inkFaint)),
                    },
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.label,
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: c.state == _CheckState.fail
                                    ? AppColors.inkDim
                                    : AppColors.ink)),
                        if (c.detail != null) ...[
                          const SizedBox(height: 1),
                          Text(c.detail!,
                              style:
                                  TextStyle(fontSize: 10.5, height: 1.4, color: AppColors.inkFaint)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Event log card
// ---------------------------------------------------------------------------

class _EventLogCard extends StatefulWidget {
  const _EventLogCard();

  @override
  State<_EventLogCard> createState() => _EventLogCardState();
}

class _EventLogCardState extends State<_EventLogCard> {
  void _onChange() => setState(() {});

  @override
  void initState() {
    super.initState();
    DiagnosticsLog.revision.addListener(_onChange);
  }

  @override
  void dispose() {
    DiagnosticsLog.revision.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = DiagnosticsLog.entries;

    return PremiumCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(AppIconName.stopwatch, size: 14, color: AppColors.inkDim),
              const SizedBox(width: 7),
              Expanded(
                child: Text('EVENT LOG',
                    style: TextStyle(
                        fontSize: AppText.overline,
                        color: AppColors.inkDim,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6)),
              ),
              Text('last ${entries.length} events',
                  style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint)),
            ],
          ),
          const SizedBox(height: 10),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Nothing recorded yet. Start a focus session, toggle a rule '
                'or open a blocked app — events appear here as they happen.',
                style: TextStyle(fontSize: 11, height: 1.5, color: AppColors.inkFaint),
              ),
            )
          else
            ...[
              for (final e in entries.take(60))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_hhmmss(e.at),
                          style: TextStyle(
                              fontSize: 10,
                              color: AppColors.inkFaint,
                              fontFeatures: const [FontFeature.tabularFigures()])),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.surface2,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(e.tag,
                            style: TextStyle(fontSize: 8.5, color: AppColors.inkDim)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(e.event,
                            style: TextStyle(fontSize: 11, height: 1.35, color: AppColors.ink)),
                      ),
                    ],
                  ),
                ),
            ],
        ],
      ),
    );
  }

  String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}
