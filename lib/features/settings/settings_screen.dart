import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/permissions_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(allPermissionsProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Local profile · not synced', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),

          _SectionLabel('PERMISSIONS'),
          const SizedBox(height: 8),
          _Card(
            children: [
              for (final p in permissions)
                _PermissionRow(
                  label: _labelFor(p.kind),
                  granted: p.granted,
                  loading: p.loading,
                ),
            ],
          ),
          const SizedBox(height: 20),

          _SectionLabel('DATA'),
          const SizedBox(height: 8),
          const _Card(
            children: [
              _NavRow(icon: Icons.save_alt_rounded, label: 'Backup to file'),
              _RowDivider(),
              _NavRow(icon: Icons.file_upload_rounded, label: 'Restore from file'),
            ],
          ),
          const SizedBox(height: 20),

          _SectionLabel('ABOUT'),
          const SizedBox(height: 8),
          const _Card(
            children: [
              _NavRow(icon: Icons.star_rounded, label: 'Rate Ulimit'),
              _RowDivider(),
              _NavRow(icon: Icons.privacy_tip_rounded, label: 'Privacy policy'),
              _RowDivider(),
              _StaticRow(label: 'Version', value: '0.1.0'),
            ],
          ),
          const SizedBox(height: 20),

          Center(
            child: TextButton(
              onPressed: () {}, // wire to a confirm dialog + AppDatabase wipe
              child: const Text('Reset all data', style: TextStyle(color: AppColors.danger, fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }

  String _labelFor(PermissionKind kind) => switch (kind) {
        PermissionKind.accessibility => 'Accessibility',
        PermissionKind.vpn => 'VPN & network',
        PermissionKind.deviceAdmin => 'Device admin',
        PermissionKind.notificationListener => 'Notification access',
        PermissionKind.biometric => 'Biometrics',
      };
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.labelSmall);
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(children: children),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();
  @override
  Widget build(BuildContext context) => const Divider(height: 1, color: AppColors.stroke);
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.label, required this.granted, required this.loading});
  final String label;
  final bool granted;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13))),
          if (loading)
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Text(
              granted ? 'Granted' : 'Pending',
              style: TextStyle(fontSize: 10.5, color: granted ? AppColors.accent : AppColors.alert),
            ),
        ],
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 16, color: AppColors.inkDim),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13))),
            const Icon(Icons.chevron_right_rounded, size: 16, color: AppColors.inkFaint),
          ],
        ),
      ),
    );
  }
}

class _StaticRow extends StatelessWidget {
  const _StaticRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13))),
          Text(value, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
