import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/icons/app_icons.dart';
import '../../core/native/enforcement_channel.dart';
import '../../core/native/permissions_channel.dart';
import '../../core/theme/premium_components.dart';
import '../../core/theme/tokens.dart';
import '../../data/permissions_providers.dart';
import '../../data/providers.dart';
import '../../shared/widgets/spring_scroll.dart';

/// Notification control: what Ulimit holds during focus, and the two
/// system capabilities that make it work. Notification contents stay
/// local — held notifications are re-posted on-device, never uploaded.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen>
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
    if (state == AppLifecycleState.resumed) {
      ref.read(permissionsRefreshTickProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(ulimitSettingsProvider).valueOrNull;
    final dndAccess = ref.watch(dndAccessGrantedProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          physics: springScrollPhysics,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            PremiumHeader(
              title: 'Notifications',
              subtitle: 'Held during focus · contents stay on-device',
            ),
            const SizedBox(height: 18),

            const Text('BEHAVIOUR',
                style: TextStyle(
                    fontSize: AppText.overline,
                    color: AppColors.inkFaint,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: AppColors.stroke),
              ),
              child: Column(
                children: [
                  _ToggleRow(
                    label: 'Pause notifications during focus',
                    sublabel: 'New notifications are held and released when the session ends',
                    value: settings?.pauseNotificationsDuringFocus ?? true,
                    onChanged: (v) =>
                        ref.read(settingsControllerProvider).setPauseNotificationsDuringFocus(v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Focus sessions and Bedtime can each override this — '
                'notifications held there are restored automatically.',
                style: TextStyle(fontSize: 11, color: AppColors.inkFaint, height: 1.5),
              ),
            ),
            const SizedBox(height: 20),

            const Text('SYSTEM ACCESS',
                style: TextStyle(
                    fontSize: AppText.overline,
                    color: AppColors.inkFaint,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            _CapabilityCard(
              icon: AppIconName.notifications,
              title: 'Notification access',
              subtitle: 'Lets Ulimit hold notifications while you focus.',
              granted: ref.watch(notificationListenerEnabledProvider).valueOrNull ?? false,
              actionLabel: 'Open settings',
              onAction: NativePermissions.openNotificationListenerSettings,
            ),
            const SizedBox(height: 10),
            _CapabilityCard(
              icon: AppIconName.notificationsOff,
              title: 'Do Not Disturb',
              subtitle: 'Bedtime and Focus can silence the whole device.',
              granted: dndAccess.valueOrNull ?? false,
              actionLabel: dndAccess.valueOrNull ?? false ? null : 'Grant access',
              onAction: () async {
                if (await EnforcementChannel.isDndAccessGranted()) return;
                await EnforcementChannel.openDndAccessSettings();
              },
            ),
          ],
        ),
      ),
    );
  }
}

final dndAccessGrantedProvider = FutureProvider<bool>((ref) {
  ref.watch(permissionsRefreshTickProvider);
  return EnforcementChannel.isDndAccessGranted();
});

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.granted,
    required this.actionLabel,
    required this.onAction,
  });

  final AppIconName icon;
  final String title;
  final String subtitle;
  final bool granted;
  final String? actionLabel;
  final Future<void> Function() onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: AppIcon(icon, size: 16, color: granted ? AppColors.ink : AppColors.inkFaint),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: AppText.title, fontWeight: FontWeight.w600, color: AppColors.ink)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(fontSize: AppText.caption, color: AppColors.inkDim)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (granted)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.ink,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: const Text('✓ On',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.bg)),
            )
          else if (actionLabel != null)
            GestureDetector(
              onTap: () => onAction(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.ink,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(actionLabel!,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.bg)),
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
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: AppText.body, color: AppColors.ink)),
                  const SizedBox(height: 2),
                  Text(sublabel,
                      style: const TextStyle(fontSize: 11, color: AppColors.inkFaint, height: 1.4)),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: AppColors.ink,
              activeColor: AppColors.bg,
            ),
          ],
        ),
      ),
    );
  }
}
