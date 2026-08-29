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
          colors: [AppColors.surface2, AppColors.surface],
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(
              active ? Icons.shield_rounded : Icons.shield_outlined,
              color: active ? AppColors.ink : AppColors.inkFaint,
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
              decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(AppRadius.pill)),
              child: const Text('✓ On', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.bg)),
            )
          else
            GestureDetector(
              onTap: () => NativePermissions.requestDeviceAdmin(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(AppRadius.pill)),
                child: const Text('Enable', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.bg)),
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
            activeColor: AppColors.ink,
          ),
        ],
      ),
    );
  }
}
