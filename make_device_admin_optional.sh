#!/usr/bin/env bash
# Makes Device Admin optional during onboarding: tapping 'Allow' opens
# the system dialog but marks the card Done regardless of the outcome,
# and it's excluded from the required-permissions app gate. The real,
# persistent toggle for it now lives in a new Parental & Lock screen,
# reachable from a new Home tile.
set -e

if [ ! -f pubspec.yaml ]; then
  echo "Run this from inside your repo root (where pubspec.yaml lives)."
  exit 1
fi

mkdir -p "lib/data"
cat > "lib/data/permissions_providers.dart" << 'PATCH_EOF'
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/native/permissions_channel.dart';

/// Bumped to force every permission provider to re-check native state —
/// call `ref.invalidate` via this after returning from system Settings
/// (Android gives no callback for "user came back from Settings", so
/// polling on resume is the standard, correct pattern here).
final permissionsRefreshTickProvider = StateProvider<int>((ref) => 0);

final accessibilityEnabledProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isAccessibilityEnabled();
});

final deviceAdminActiveProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isDeviceAdminActive();
});

final notificationListenerEnabledProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isNotificationListenerEnabled();
});

final vpnPermissionGrantedProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.hasVpnPermission();
});

final postNotificationsGrantedProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isPostNotificationsGranted();
});

final biometricAvailableProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return NativePermissions.isBiometricAvailable();
});

/// Device Admin is requested during onboarding but never *required* —
/// tapping "Allow" opens the system dialog once; whatever the user
/// decides there, onboarding treats the card as handled so it never
/// blocks app access. This flag is what lets the card show "Done"
/// even when the native isDeviceAdminActive() check is still false.
/// The real, persistent toggle for actually enabling it lives in the
/// Parental & Lock screen instead.
final deviceAdminAcknowledgedProvider = StateProvider<bool>((ref) => false);

/// One combined item type the onboarding screen renders from — keeps
/// the widget dumb (map over a list) instead of five near-identical
/// card widgets hand-wired to five different providers.
enum PermissionKind { accessibility, vpn, deviceAdmin, notificationListener, biometric }

class PermissionStatus {
  const PermissionStatus({required this.kind, required this.granted, required this.loading});
  final PermissionKind kind;
  final bool granted;
  final bool loading;
}

final allPermissionsProvider = Provider<List<PermissionStatus>>((ref) {
  final accessibility = ref.watch(accessibilityEnabledProvider);
  final vpn = ref.watch(vpnPermissionGrantedProvider);
  final deviceAdmin = ref.watch(deviceAdminActiveProvider);
  final notifications = ref.watch(notificationListenerEnabledProvider);
  final biometric = ref.watch(biometricAvailableProvider);

  final deviceAdminAcknowledged = ref.watch(deviceAdminAcknowledgedProvider);

  PermissionStatus build(PermissionKind kind, AsyncValue<bool> value) => PermissionStatus(
        kind: kind,
        granted: value.valueOrNull ?? false,
        loading: value.isLoading,
      );

  return [
    build(PermissionKind.accessibility, accessibility),
    build(PermissionKind.vpn, vpn),
    // Shows "Done" once either the OS reports it active, or the user
    // has been through the request flow once this session — see
    // deviceAdminAcknowledgedProvider's doc comment.
    PermissionStatus(
      kind: PermissionKind.deviceAdmin,
      granted: (deviceAdmin.valueOrNull ?? false) || deviceAdminAcknowledged,
      loading: deviceAdmin.isLoading,
    ),
    build(PermissionKind.notificationListener, notifications),
    build(PermissionKind.biometric, biometric),
  ];
});

/// True once every *required* permission is granted. Device Admin and
/// Biometrics are both excluded deliberately: Biometrics is genuinely
/// optional, and Device Admin — while useful for Invincible Mode's
/// tamper resistance — shouldn't block someone from using the app at
/// all just because they declined a device-admin prompt on first run.
/// It's offered again, properly, from Parental & Lock.
final requiredPermissionsGrantedProvider = Provider<bool>((ref) {
  final all = ref.watch(allPermissionsProvider);
  const notRequired = {PermissionKind.biometric, PermissionKind.deviceAdmin};
  return all.where((p) => !notRequired.contains(p.kind)).every((p) => p.granted);
});
PATCH_EOF

mkdir -p "lib/features/onboarding"
cat > "lib/features/onboarding/permissions_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../core/native/permissions_channel.dart';
import '../../data/permissions_providers.dart';

class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key, required this.onAllGranted});

  /// Called once every non-optional permission is granted, so the
  /// caller can advance the router — kept as a callback rather than
  /// this screen owning navigation, so it's reusable from both first
  /// launch and Settings → Permissions.
  final VoidCallback onAllGranted;

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android gives no callback for "user returned from Settings" — the
    // correct, standard pattern is to re-check every relevant permission
    // when the app resumes, since that's the only reliable signal.
    if (state == AppLifecycleState.resumed) {
      ref.read(permissionsRefreshTickProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(allPermissionsProvider);

    // Biometric is optional (see design) — required count excludes it.
    const notRequired = {PermissionKind.biometric, PermissionKind.deviceAdmin};
    final required = permissions.where((p) => !notRequired.contains(p.kind));
    final grantedCount = required.where((p) => p.granted).length;
    final requiredTotal = required.length;
    final allRequiredGranted = grantedCount == requiredTotal;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            children: [
              const SizedBox(height: 6),
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(Icons.lock_rounded, color: AppColors.accentSoft, size: 22),
              ),
              const SizedBox(height: 12),
              Text(
                'Ulimit needs a few permissions',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              Text(
                'Everything stays on your device — nothing is ever uploaded. '
                'Each permission only powers the feature next to it.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView.separated(
                  itemCount: permissions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _PermissionCard(status: permissions[i]),
                ),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: requiredTotal == 0 ? 0 : grantedCount / requiredTotal,
                  minHeight: 5,
                  backgroundColor: AppColors.stroke,
                  valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                ),
              ),
              const SizedBox(height: 8),
              Text('$grantedCount of $requiredTotal granted',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: allRequiredGranted ? widget.onAllGranted : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.ink,
                    disabledBackgroundColor: AppColors.surface2,
                    padding: const EdgeInsets.all(15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: Text(
                    'Continue',
                    style: TextStyle(
                      color: allRequiredGranted ? AppColors.bg : AppColors.inkFaint,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionMeta {
  const _PermissionMeta(this.title, this.description, this.icon, this.iconColor, this.optional);
  final String title;
  final String description;
  final IconData icon;
  final Color iconColor;
  final bool optional;
}

const _meta = {
  PermissionKind.accessibility: _PermissionMeta(
    'Accessibility',
    'The core engine — detects app usage, enforces limits, and shows the block screen instantly.',
    Icons.visibility_rounded,
    AppColors.danger,
    false,
  ),
  PermissionKind.vpn: _PermissionMeta(
    'VPN & Network',
    'Creates a local, on-device filter for internet and website blocking.',
    Icons.public_rounded,
    AppColors.accentSoft,
    false,
  ),
  PermissionKind.deviceAdmin: _PermissionMeta(
    'Device Admin',
    "Stops Ulimit from being uninstalled or force-stopped to bypass a limit. "
    "Optional here — you can turn this on later in Parental & Lock.",
    Icons.shield_rounded,
    AppColors.accentSoft,
    false,
  ),
  PermissionKind.notificationListener: _PermissionMeta(
    'Notification Access',
    'Lets Ulimit batch or mute notifications during focus sessions.',
    Icons.notifications_rounded,
    AppColors.accentSoft,
    false,
  ),
  PermissionKind.biometric: _PermissionMeta(
    'Biometrics',
    'Optional — protects your limits from being changed by others.',
    Icons.fingerprint_rounded,
    AppColors.accentSoft,
    true,
  ),
};

class _PermissionCard extends ConsumerWidget {
  const _PermissionCard({required this.status});
  final PermissionStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = _meta[status.kind]!;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: meta.iconColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(meta.icon, size: 15, color: meta.iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(meta.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13)),
                const SizedBox(height: 2),
                Text(meta.description, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _ActionButton(status: status, optional: meta.optional),
        ],
      ),
    );
  }
}

class _ActionButton extends ConsumerWidget {
  const _ActionButton({required this.status, required this.optional});
  final PermissionStatus status;
  final bool optional;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (status.granted) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(AppRadius.pill)),
        child: const Text('✓ Done', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
      );
    }

    return GestureDetector(
      onTap: status.loading ? null : () => _handleTap(ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: optional ? AppColors.surface2 : AppColors.accent,
          border: optional ? Border.all(color: AppColors.stroke) : null,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          optional ? 'Skip' : 'Allow',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: optional ? AppColors.inkDim : Colors.white,
          ),
        ),
      ),
    );
  }

  Future<void> _handleTap(WidgetRef ref) async {
    // Accessibility and Notification Listener can only be toggled from
    // system Settings — Android has no in-app grant dialog for either.
    // The rest support a direct system dialog.
    switch (status.kind) {
      case PermissionKind.accessibility:
        await NativePermissions.openAccessibilitySettings();
      case PermissionKind.notificationListener:
        await NativePermissions.openNotificationListenerSettings();
      case PermissionKind.vpn:
        await NativePermissions.requestVpnPermission();
      case PermissionKind.deviceAdmin:
        // Fire the system dialog, but don't wait on or gate anything
        // to its result — whatever the user picks there, onboarding
        // moves on. See deviceAdminAcknowledgedProvider's doc comment.
        await NativePermissions.requestDeviceAdmin();
        ref.read(deviceAdminAcknowledgedProvider.notifier).state = true;
      case PermissionKind.biometric:
        // "Skip" for the optional card — nothing to request, just move
        // on; availability is a device capability, not a togglable
        // permission, so there's nothing else to do here.
        return;
    }
    // VPN/Device Admin dialogs resolve synchronously enough that an
    // immediate re-check is worthwhile; Accessibility/Notification
    // Listener rely on the lifecycle-resume re-check instead since the
    // user is leaving the app to a Settings screen.
    ref.read(permissionsRefreshTickProvider.notifier).state++;
  }
}
PATCH_EOF

mkdir -p "lib/core/router"
cat > "lib/core/router/app_router.dart" << 'PATCH_EOF'
import 'package:go_router/go_router.dart';
import '../../shared/widgets/nav_shell.dart';
import '../../features/home/home_screen.dart';
import '../../features/focus/focus_screen.dart';
import '../../features/limits/limits_screen.dart';
import '../../features/bedtime/bedtime_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/parental/parental_screen.dart';
import 'morph_transition.dart';

/// Route paths as constants — avoids magic strings scattered across
/// 15+ screens and makes renames a one-line change.
abstract final class Routes {
  static const home = '/';
  static const focus = '/focus';
  static const limits = '/limits';
  static const bedtime = '/bedtime';
  static const settings = '/settings';
  static const parental = '/parental';
}

final appRouter = GoRouter(
  initialLocation: Routes.home,
  routes: [
    // ShellRoute keeps the floating nav bar mounted across tab switches
    // instead of rebuilding it (and its icons/animations) on every nav —
    // this is the single biggest jank source in bottom-nav apps that get
    // it wrong.
    ShellRoute(
      builder: (context, state, child) => NavShell(child: child),
      routes: [
        GoRoute(
          path: Routes.home,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const HomeScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.focus,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const FocusScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.limits,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const LimitsScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.bedtime,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const BedtimeScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.settings,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const SettingsScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
      ],
    ),
    // Detail screens (App Limits detail, Internet & Sites, blocking
    // overlay, etc.) push OUTSIDE the shell using MorphPage so the nav
    // bar correctly disappears rather than fighting a full-screen modal.
    GoRoute(
      path: Routes.parental,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const ParentalScreen(),
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        // Same fade+scale curve as MorphPage (see morph_transition.dart) —
        // duplicated inline rather than reused because MorphPage is a
        // PageRouteBuilder for imperative Navigator.push, not a go_router
        // Page; CustomTransitionPage is go_router's equivalent shape.
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween(begin: 0.97, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    ),
  ],
);
PATCH_EOF

mkdir -p "lib/features/home"
cat > "lib/features/home/home_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/tokens.dart';
import '../../data/providers.dart';
import '../../data/home_data_providers.dart';
import '../../shared/widgets/limit_ring.dart';
import '../../shared/widgets/trend_chart.dart';
import '../../shared/widgets/pressable_scale.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenTime = ref.watch(todayScreenTimeProvider);
    final budgetMinutes = ref.watch(dailyBudgetProvider);
    final score = ref.watch(limitScoreProvider);
    final streak = ref.watch(currentStreakProvider);
    final weeklyUsage = ref.watch(weeklyScreenTimeHoursProvider);
    final weeklyFocusSeconds = ref.watch(weeklyFocusSecondsProvider);
    final weeklyFocusHours = ref.watch(weeklyFocusHoursByDayProvider);
    final weeklyPickups = ref.watch(weeklyPickupsProvider);

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topCenter,
          radius: 1.15,
          colors: [Color(0x3A8B7FE8), Colors.transparent],
          stops: [0.0, 0.6],
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
          children: [
            _Header(streak: streak.valueOrNull ?? 0),
            const SizedBox(height: 18),

            _LimitScoreBanner(score: score),
            const SizedBox(height: 22),

            Center(
              child: _buildRing(screenTime, budgetMinutes),
            ),
            const SizedBox(height: 28),

            const _SectionLabel('THIS WEEK'),
            const SizedBox(height: 10),
            _WeeklyTrendCard(weeklyHours: weeklyUsage),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _MiniTrendCard(
                    label: 'Focus time',
                    valueText: _formatFocusTotal(weeklyFocusSeconds.valueOrNull),
                    values: weeklyFocusHours.valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MiniTrendCard(
                    label: 'Pickups / day',
                    valueText: _formatPickupsAvg(weeklyPickups.valueOrNull),
                    values: weeklyPickups.valueOrNull ?? const [0, 0, 0, 0, 0, 0, 0],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),

            const _SectionLabel('CONTROLS'),
            const SizedBox(height: 10),
            const _ControlsGrid(),
          ],
        ),
      ),
    );
  }

  Widget _buildRing(AsyncValue<Duration> screenTime, AsyncValue<int> budgetMinutes) {
    if (screenTime.isLoading || budgetMinutes.isLoading) {
      return const LimitRing(progress: 0, size: 130, trackColor: AppColors.stroke);
    }
    final used = screenTime.valueOrNull ?? Duration.zero;
    final budget = Duration(minutes: budgetMinutes.valueOrNull ?? 240);
    return _ScreenTimeRing(used: used, budget: budget);
  }

  String _formatFocusTotal(int? seconds) {
    if (seconds == null || seconds == 0) return '0m';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }

  String _formatPickupsAvg(List<double>? days) {
    if (days == null || days.isEmpty) return '—';
    final avg = days.reduce((a, b) => a + b) / days.length;
    return avg.round().toString();
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.streak});
  final int streak;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Today', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text(_formattedDate(), style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        if (streak > 0) _StreakBadge(days: streak),
      ],
    );
  }

  String _formattedDate() {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final now = DateTime.now();
    return '${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
  }
}

class _StreakBadge extends StatelessWidget {
  const _StreakBadge({required this.days});
  final int days;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_fire_department_rounded, size: 13, color: AppColors.accentSoft),
          const SizedBox(width: 5),
          Text('$days day streak',
              style: const TextStyle(fontSize: 11, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.labelSmall);
}

class _ScreenTimeRing extends StatelessWidget {
  const _ScreenTimeRing({required this.used, required this.budget});
  final Duration used;
  final Duration budget;

  @override
  Widget build(BuildContext context) {
    final remaining = budget - used;
    final safeBudget = budget.inSeconds <= 0 ? 1 : budget.inSeconds;
    final progress = 1 - (used.inSeconds / safeBudget).clamp(0.0, 1.0);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: progress),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: AppColors.accent.withOpacity(0.18), blurRadius: 40, spreadRadius: 4),
          ],
        ),
        child: LimitRing(
          progress: value,
          size: 130,
          strokeWidth: 9,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_formatDuration(remaining), style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text('LEFT TODAY', style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final clamped = d.isNegative ? Duration.zero : d;
    final h = clamped.inHours;
    final m = clamped.inMinutes % 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _LimitScoreBanner extends StatelessWidget {
  const _LimitScoreBanner({required this.score});
  final AsyncValue<LimitScore> score;

  @override
  Widget build(BuildContext context) {
    final data = score.valueOrNull;

    return PressableScale(
      onTap: () {}, // wire to Routes.score detail push
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.stroke),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [AppColors.accent.withOpacity(0.14), AppColors.surface],
            stops: const [0.0, 0.65],
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(colors: [AppColors.accent, AppColors.accentSoft, AppColors.accent]),
              ),
              child: Center(
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(color: AppColors.surface, shape: BoxShape.circle),
                  child: const Icon(Icons.shield_rounded, size: 18, color: AppColors.ink),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(data == null ? '—' : '${data.score}',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 6),
                      Text('Limit',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600, color: AppColors.inkDim)),
                    ],
                  ),
                  Text(
                    data == null
                        ? 'Calculating…'
                        : '${data.tier.name} tier · ${data.toNextTier} to next badge',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.accent, size: 18),
          ],
        ),
      ),
    );
  }
}

class _WeeklyTrendCard extends StatelessWidget {
  const _WeeklyTrendCard({required this.weeklyHours});
  final AsyncValue<List<double>> weeklyHours;

  @override
  Widget build(BuildContext context) {
    final values = weeklyHours.valueOrNull;
    final hasData = values != null && values.any((v) => v > 0);
    final avg = hasData ? values.reduce((a, b) => a + b) / values.length : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Avg. daily screen time',
              style: TextStyle(fontSize: 12, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            hasData ? _formatHours(avg) : 'No data yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          if (hasData)
            TrendAreaChart(values: values)
          else
            // First-run / no-Accessibility-permission state — an empty
            // chart card reads as broken, so say so explicitly instead.
            const SizedBox(
              height: 84,
              child: Center(
                child: Text(
                  'Enable Accessibility access to start tracking',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: AppColors.inkFaint),
                ),
              ),
            ),
          const SizedBox(height: 4),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _DayLabel('M'), _DayLabel('T'), _DayLabel('W'), _DayLabel('T'),
              _DayLabel('F'), _DayLabel('S'), _DayLabel('S'),
            ],
          ),
        ],
      ),
    );
  }

  String _formatHours(double hours) {
    final h = hours.floor();
    final m = ((hours - h) * 60).round();
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 9, color: AppColors.inkFaint));
}

class _MiniTrendCard extends StatelessWidget {
  const _MiniTrendCard({
    required this.label,
    required this.valueText,
    required this.values,
  });

  final String label;
  final String valueText;
  final List<double> values;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.inkDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Sparkline(values: values),
          const SizedBox(height: 6),
          Text(valueText,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _ControlsGrid extends StatelessWidget {
  const _ControlsGrid();

  static const _tiles = [
    ('Focus', Icons.track_changes_rounded, 'Start a session', null),
    ('App Limits', Icons.grid_view_rounded, 'Manage groups', null),
    ('App Blocking', Icons.block_rounded, 'Manage blocked apps', null),
    ('Internet & Sites', Icons.public_rounded, 'VPN & filters', null),
    ('Notifications', Icons.notifications_rounded, 'Manage delivery', null),
    ('Bedtime', Icons.dark_mode_rounded, 'Manage schedule', null),
    ('Parental & Lock', Icons.shield_rounded, 'Device admin & tamper protection', Routes.parental),
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _tiles.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 9,
        crossAxisSpacing: 9,
        childAspectRatio: 1.5,
      ),
      itemBuilder: (context, i) {
        final (title, icon, subtitle, route) = _tiles[i];
        return _ControlTile(title: title, icon: icon, subtitle: subtitle, route: route);
      },
    );
  }
}

class _ControlTile extends StatelessWidget {
  const _ControlTile({required this.title, required this.icon, required this.subtitle, this.route});
  final String title;
  final IconData icon;
  final String subtitle;
  // Null for tiles whose detail screens aren't built yet -- tapping
  // those is a harmless no-op rather than a route-not-found crash.
  final String? route;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: route == null ? () {} : () => context.push(route!),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 15, color: AppColors.accentSoft),
            ),
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 12.5)),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10)),
          ],
        ),
      ),
    );
  }
}
PATCH_EOF

mkdir -p "lib/features/parental"
cat > "lib/features/parental/parental_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../core/native/permissions_channel.dart';
import '../../data/permissions_providers.dart';

class ParentalScreen extends ConsumerStatefulWidget {
  const ParentalScreen({super.key});

  @override
  ConsumerState<ParentalScreen> createState() => _ParentalScreenState();
}

class _ParentalScreenState extends ConsumerState<ParentalScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Same pattern as the onboarding permissions screen — Android gives
    // no callback for "returned from the device-admin system dialog",
    // so re-check on resume.
    if (state == AppLifecycleState.resumed) {
      ref.read(permissionsRefreshTickProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Reads the *real* native state directly, not the onboarding
    // "acknowledged" shortcut — this screen is where Device Admin
    // actually gets turned on for real, so it should never lie about
    // whether it's genuinely active.
    final deviceAdminActive = ref.watch(deviceAdminActiveProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.arrow_back_rounded, size: 14, color: AppColors.inkDim),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Parental & Lock', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 19)),
                  Text('Protects settings from being changed', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          deviceAdminActive.when(
            data: (active) => _StatusCard(active: active),
            loading: () => const _StatusCard(active: false, loading: true),
            error: (_, __) => const _StatusCard(active: false),
          ),
          const SizedBox(height: 16),

          Text('PROTECTION', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.stroke),
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Column(
              children: [
                deviceAdminActive.when(
                  data: (active) => _DeviceAdminRow(active: active),
                  loading: () => const _DeviceAdminRow(active: false, loading: true),
                  error: (_, __) => const _DeviceAdminRow(active: false),
                ),
                const Divider(height: 1, color: AppColors.stroke),
                _ToggleRow(
                  label: 'Require biometric to edit',
                  sublabel: 'Face unlock or fingerprint',
                  value: false,
                  onChanged: (_) {}, // wire to a real settings row once biometric-lock is built
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.active, this.loading = false});
  final bool active;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.accent.withOpacity(active ? 0.12 : 0.04), AppColors.surface],
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(active ? 0.18 : 0.1),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(
              active ? Icons.shield_rounded : Icons.shield_outlined,
              color: active ? AppColors.accentSoft : AppColors.inkFaint,
              size: 22,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            loading ? 'Checking…' : (active ? 'Device Admin is active' : 'Device Admin is off'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            active
                ? "Ulimit can't be uninstalled or force-stopped without deactivating this first."
                : 'Turn this on for extra tamper resistance — optional, not required to use the app.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _DeviceAdminRow extends StatelessWidget {
  const _DeviceAdminRow({required this.active, this.loading = false});
  final bool active;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Block uninstall', style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13)),
                Text('Requires Device Admin', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10.5)),
              ],
            ),
          ),
          if (loading)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else if (active)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(AppRadius.pill)),
              child: const Text('✓ On', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
            )
          else
            GestureDetector(
              onTap: () => NativePermissions.requestDeviceAdmin(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(AppRadius.pill)),
                child: const Text('Enable', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.sublabel,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final String sublabel;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13)),
                Text(sublabel, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10.5)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: AppColors.accent,
          ),
        ],
      ),
    );
  }
}
PATCH_EOF

git add -A
git -c user.email="dev@ulimit.app" -c user.name="Ulimit Dev" commit -m "Make Device Admin optional in onboarding; add Parental & Lock screen for the real toggle"
git push

echo "Pushed. Removing this script."
rm -- "$0"
