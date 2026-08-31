
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/icons/app_icons.dart';
import '../../core/theme/tokens.dart';
import 'app_card_palette.dart';
import 'app_sheet.dart';
import '../../core/native/enforcement_channel.dart' show InstalledApp;
import '../../data/apps_repository.dart';
import '../../data/providers.dart';
import 'pressable_scale.dart';
import 'spring_scroll.dart';

/// Cached app icon: decodes the native PNG bytes once per package. A
/// gray initial letter shows when an icon is unavailable (non-Android,
/// revoked catalog) so lists stay visually stable.
class AppIconView extends ConsumerWidget {
  const AppIconView({super.key, required this.packageName, this.size = 22, this.radius = 6});

  final String packageName;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = ref.watch(appIconProvider(packageName));
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: icon.when(
        data: (bytes) => bytes == null
            ? _FallbackLetter(packageName: packageName, size: size)
            : Image.memory(bytes, width: size, height: size, fit: BoxFit.contain, gaplessPlayback: true),
        loading: () => const SizedBox.shrink(),
        error: (_, __) => _FallbackLetter(packageName: packageName, size: size),
      ),
    );
  }
}

class _FallbackLetter extends StatelessWidget {
  const _FallbackLetter({required this.packageName, required this.size});
  final String packageName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = packageName.isEmpty ? '?' : packageName[0].toUpperCase();
    return Text(
      letter,
      style: TextStyle(fontSize: size * 0.5, color: AppColors.inkDim, fontWeight: FontWeight.w600),
    );
  }
}

/// Bottom sheet listing installed apps with search — used by blocking,
/// limits, groups, bedtime and internet-blocking flows.
///
/// `multiSelect` flips it into a checkbox picker that returns a set of
/// package names; otherwise it returns a single package name (or null).
Future<dynamic> showAppSelector(
  BuildContext context, {
  required String title,
  bool multiSelect = false,
  Set<String> initiallySelected = const {},
}) {
  return showAppSheet<dynamic>(
    context: context,
    title: title,
    subtitle: multiSelect ? 'Select one or more applications' : null,
    builder: (_, scrollController) => _AppSelectorSheet(
      multiSelect: multiSelect,
      initiallySelected: initiallySelected,
      scrollController: scrollController,
    ),
  );
}

class _AppSelectorSheet extends ConsumerStatefulWidget {
  const _AppSelectorSheet({
    required this.multiSelect,
    required this.initiallySelected,
    required this.scrollController,
  });

  final bool multiSelect;
  final Set<String> initiallySelected;

  /// The sheet system's controller — MUST be attached to the list so
  /// at-top downward drags hand off to dragging the sheet.
  final ScrollController scrollController;

  @override
  ConsumerState<_AppSelectorSheet> createState() => _AppSelectorSheetState();
}

class _AppSelectorSheetState extends ConsumerState<_AppSelectorSheet> {
  String _query = '';
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initiallySelected};
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(appsCatalogProvider);
    final usage = ref.watch(todayUsageByPackageProvider).valueOrNull ?? const {};

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            style: TextStyle(color: AppColors.ink, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search applications…',
              hintStyle: TextStyle(color: AppColors.inkFaint, fontSize: 13.5),
              prefixIcon: Padding(
                padding: const EdgeInsets.all(12),
                child: AppIcon(AppIconName.search, size: 18, color: AppColors.inkFaint),
              ),
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        Expanded(
          child: catalog.when(
            loading: () => const Center(
              child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            error: (e, _) => Center(
              child: Text(
                'Could not load applications.\nCheck that Ulimit has query access.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.inkFaint, fontSize: 12.5),
              ),
            ),
            data: (data) {
              final apps = data.apps
                  .where((a) => a.displayName.toLowerCase().contains(_query.toLowerCase()))
                  .toList();
              if (apps.isEmpty) {
                return Center(
                  child: Text('No applications found',
                      style: TextStyle(color: AppColors.inkFaint, fontSize: 12.5)),
                );
              }
              return GridView.builder(
                controller: widget.scrollController,
                physics: springScrollPhysics,
                shrinkWrap: true,
                // 2 columns on normal phone widths; the sheet's width
                // is the screen width, so maxExtent keeps 2 per row
                // across common Android sizes.
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.78,
                ),
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                itemCount: apps.length,
                itemBuilder: (context, i) {
                  final app = apps[i];
                  final isSelected = _selected.contains(app.packageName);
                  final used = usage[app.packageName] ?? 0;
                  return _AppCard(
                    app: app,
                    usageText: used > 0 ? _formatMinutes(used ~/ 60) : null,
                    selected: widget.multiSelect && isSelected,
                    onTap: () {
                      if (!widget.multiSelect) {
                        Navigator.of(context).pop(app.packageName);
                        return;
                      }
                      setState(() {
                        isSelected ? _selected.remove(app.packageName) : _selected.add(app.packageName);
                      });
                    },
                  );
                },
              );
            },
          ),
        ),
        if (widget.multiSelect)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_selected.length} selected',
                    style: TextStyle(color: AppColors.inkDim, fontSize: 12.5),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_selected),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.ink,
                    foregroundColor: AppColors.bg,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

String _formatMinutes(int minutes) {
  if (minutes <= 0) return '0m';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

/// Premium app tile: the icon's dominant color expanded into a solid,
/// rounded card. Icon near the top, name below, usage as supporting
/// line, selected state as a corner check. Matte (no border), no
/// gradient, minimal shadow — the color IS the identity.
class _AppCard extends ConsumerWidget {
  const _AppCard({
    required this.app,
    required this.selected,
    this.usageText,
    this.onTap,
  });

  final InstalledApp app;
  final bool selected;
  final String? usageText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = ref.watch(appIconProvider(app.packageName));

    // Color extraction is cached per package; only the first card build
    // pays the decode cost. The card renders in the fallback mono tone
    // while the extraction is in flight so there's never a white flash.
    final paletteFuture = AppCardPalette.colorFor(app.packageName, app.iconBytes);

    return PressableScale(
      onTap: onTap,
      child: FutureBuilder<AppCardColor>(
        future: paletteFuture,
        builder: (context, snapshot) {
          final palette = snapshot.data ?? AppCardColor.fallback();
          return LayoutBuilder(
            builder: (context, constraints) {
              // Icon size scales with card width: ~38% of card width,
              // clamped to a comfortable 52–72px band.
              final iconSize = (constraints.maxWidth * 0.38).clamp(52.0, 72.0);
              return Container(
                decoration: BoxDecoration(
                  // Dominant color at the top, shading gently darker at
                  // the bottom — a depth cue, never a different hue.
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [palette.background, palette.bottom],
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  boxShadow: [
                    // Very subtle depth — the solid color is the
                    // dominant element, never a floating card illusion.
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (selected)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: palette.text,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.check_rounded,
                              size: 14, color: palette.background),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: iconSize * 1.4,
                            child: Center(
                              child: Hero(
                                tag: 'app-icon-${app.packageName}',
                                child: _CardIcon(
                                  packageName: app.packageName,
                                  bytes: app.iconBytes,
                                  icon: icon,
                                  size: iconSize,
                                ),
                              ),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            app.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: palette.text,
                              letterSpacing: 0.1,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            usageText == null ? 'No usage yet' : '$usageText today',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: palette.text.withValues(alpha: 0.78),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// The card's icon: original artwork, never recolored, on a white
/// rounded tile so it always stays legible against any card color.
class _CardIcon extends StatelessWidget {
  const _CardIcon({
    required this.packageName,
    required this.icon,
    required this.size,
    this.bytes,
  });

  final String packageName;
  final AsyncValue<Uint8List?> icon;
  final double size;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final iconBytes = bytes ?? (icon.valueOrNull);
    // The icon artwork itself in rounded corners — no tile, no border.
    // A soft downward shadow separates it from the card background.
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: size * 0.22,
            offset: Offset(0, size * 0.10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: SizedBox(
          width: size,
          height: size,
          child: icon.when(
            data: (b) {
              final effective = b ?? iconBytes;
              return effective == null
                  ? _FallbackLetter(packageName: packageName, size: size)
                  : Image.memory(
                      effective,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    );
            },
            loading: () => iconBytes == null
                ? const SizedBox.shrink()
                : Image.memory(
                    iconBytes!,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
            error: (_, __) => _FallbackLetter(packageName: packageName, size: size),
          ),
        ),
      ),
    );
  }
}

/// Duration presets used by the manual-blocking flow. Returned as the
/// exact [Duration], plus flags for the special cases.
class DurationChoice {
  const DurationChoice._(this.label, this.duration, {this.untilTonight = false, this.permanent = false});
  final String label;
  final Duration? duration;
  final bool untilTonight;
  final bool permanent;

  static const choices = [
    DurationChoice._('30 minutes', Duration(minutes: 30)),
    DurationChoice._('1 hour', Duration(hours: 1)),
    DurationChoice._('3 hours', Duration(hours: 3)),
    DurationChoice._('Until tonight', null, untilTonight: true),
    DurationChoice._('1 day', Duration(days: 1)),
    DurationChoice._('3 days', Duration(days: 3)),
    DurationChoice._('7 days', Duration(days: 7)),
    DurationChoice._('Until manually removed', null, permanent: true),
  ];
}

/// Resolves the special duration choices to concrete timestamps.
DateTime? resolveChoiceEnd(BuildContext context, DurationChoice choice) {
  if (choice.permanent) return null; // permanent — no expiry
  if (choice.untilTonight) {
    final now = DateTime.now();
    // "Tonight" = 23:00 today, or tomorrow if it's already past 23:00.
    var tonight = DateTime(now.year, now.month, now.day, 23);
    if (!tonight.isAfter(now)) tonight = tonight.add(const Duration(days: 1));
    return tonight;
  }
  return DateTime.now().add(choice.duration!);
}

/// Shows the duration picker and returns the chosen end timestamp
/// (null = permanent) or null when cancelled.
Future<DateTime?> showDurationSelector(BuildContext context, String appLabel) async {
  final choice = await showAppSheet<DurationChoice>(
    context: context,
    title: 'Block $appLabel',
    subtitle: 'Access is restored automatically when the block ends.',
    initialSize: 0.62,
    minSize: 0.35,
    builder: (sheetContext, scrollController) => ListView(
      controller: scrollController,
      physics: springScrollPhysics,
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        for (final choice in DurationChoice.choices)
          InkWell(
            onTap: () => Navigator.of(sheetContext).pop(choice),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
              child: Text(choice.label,
                  style: TextStyle(fontSize: 14, color: AppColors.ink)),
            ),
          ),
      ],
    ),
  );
  if (choice == null) return null;
  return resolveChoiceEnd(context, choice);
}
