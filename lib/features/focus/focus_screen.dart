import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/icons/app_icons.dart';
import '../../core/native/permissions_channel.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/tokens.dart';
import '../../data/apps_repository.dart';
import '../../data/db/app_database.dart';
import '../../data/doomscroll_apps.dart';
import '../../data/doomscroll_providers.dart';
import '../../data/focus_providers.dart';
import '../../data/focus_tags_provider.dart';
import '../../data/providers.dart';
import '../../shared/widgets/app_selector.dart';
import '../../shared/widgets/app_sheet.dart';
import '../../shared/widgets/duration_flow.dart';
import '../../shared/widgets/limit_ring.dart';
import '../../shared/widgets/pressable_scale.dart';
import '../../shared/widgets/session_tag_editor.dart';
import '../../shared/widgets/spring_scroll.dart';

class FocusScreen extends ConsumerWidget {
  const FocusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(activeFocusSessionProvider).valueOrNull;

    return Container(
      color: AppColors.bg,
      // Top spacing is owned by NavShell's collapsing inset — no
      // SafeArea here, so scrolling expands content to full height.
      child: session == null ? _IdleFocusView() : _RunningFocusView(session: session),
    );
  }
}

// ---------------------------------------------------------------------------
// Idle — start flow
// ---------------------------------------------------------------------------

class _IdleFocusView extends ConsumerStatefulWidget {
   _IdleFocusView();

  @override
  ConsumerState<_IdleFocusView> createState() => _IdleFocusViewState();
}

class _IdleFocusViewState extends ConsumerState<_IdleFocusView> {
  static const _labels = ['Deep Work', 'Study', 'Reading', 'Writing'];
  static const _durations = [15, 25, 45, 60, 90, 120];

  int _minutes = 25;
  // null = timed session; -1 = "until I turn it off" (untimed).
  bool _untimed = false;
  List<String> _blockedApps = const [];
  bool _pauseNotifications = true;
  bool _blockInternet = false;
  bool _blockWebsites = false;
  bool _invincible = false;
  bool _starting = false;
  // One-switch preset: blocks the major doomscroll apps (see
  // kDoomscrollPackages) for this session.
  bool _blockDoomscroll = false;

  // Selected custom tag (name + color) or null for built-in labels.
  FocusTag? _selectedTag;
  // Which built-in label is selected when no custom tag is.
  String _selectedBuiltIn = 'Deep Work';

  @override
  void initState() {
    super.initState();
    // Default duration comes from Settings.
    final settings = ref.read(ulimitSettingsProvider).valueOrNull;
    if (settings != null && _durations.contains(settings.defaultFocusMinutes)) {
      _minutes = settings.defaultFocusMinutes;
    } else {
      _loadDefaultDuration();
    }
  }

  Future<void> _loadDefaultDuration() async {
    // The settings row may not be loaded on first frame; read once and
    // adopt its default if still unset.
    final settings = await ref.read(ulimitSettingsProvider.future);
    if (!mounted) return;
    if (_durations.contains(settings.defaultFocusMinutes)) {
      setState(() => _minutes = settings.defaultFocusMinutes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final customTags = ref.watch(focusTagsProvider).valueOrNull ?? const <FocusTag>[];
    final colored = ref.watch(coloredSessionTagsProvider).valueOrNull ?? false;

    return ListView(
      physics: springScrollPhysics,
      padding: EdgeInsets.fromLTRB(20, 16, 20, ref.watch(hideNavBarProvider).valueOrNull == true ? navBarHiddenInset : navBarPillInset),
      children: [
        Text('Focus', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('One session. One intention.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 22),

        Text('SESSION',
            style: TextStyle(fontSize: AppText.overline, color: AppColors.inkFaint, letterSpacing: 0.6)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // Built-in labels — plain tap selects, no editor.
            for (final label in _labels)
              HoldToEditChip(
                label: label,
                selected: _selectedTag == null && _selectedBuiltIn == label,
                onTapped: () => setState(() {
                  _selectedBuiltIn = label;
                  _selectedTag = null;
                }),
              ),
            // User-created tags — tap selects; hold 3s opens the editor.
            for (final tag in customTags)
              HoldToEditChip(
                label: tag.name,
                selected: _selectedTag?.id == tag.id,
                color: colored ? Color(tag.colorValue) : null,
                onTapped: () => setState(() => _selectedTag = tag),
                onHold: () => _editTag(context, tag),
              ),
            // The "+ New" chip — always at the end of the row.
            _NewTagChip(onTap: () => _createTag(context)),
          ],
        ),
        const SizedBox(height: 22),

        Text('DURATION',
            style: TextStyle(fontSize: AppText.overline, color: AppColors.inkFaint, letterSpacing: 0.6)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in _durations)
              HoldToEditChip(
                label: '$m min',
                selected: !_untimed && _minutes == m,
                onTapped: () => setState(() {
                  _minutes = m;
                  _untimed = false;
                }),
              ),
            _CustomDurationChip(
              label: _customLabel(),
              selected: !_untimed && _customMinutes != null,
              onTap: _pickCustomDuration,
            ),
            HoldToEditChip(
              label: 'Until I turn it off',
              selected: _untimed,
              onTapped: () => setState(() => _untimed = true),
            ),
          ],
        ),
        const SizedBox(height: 22),

        Text('APPS TO BLOCK',
            style: TextStyle(fontSize: AppText.overline, color: AppColors.inkFaint, letterSpacing: 0.6)),
        const SizedBox(height: 10),
        Row(
          children: [
            _AppsPill(
              label: _blockedApps.isEmpty ? 'Block apps' : '${_blockedApps.length} blocked',
              onTap: _pickApps,
            ),
          ],
        ),
        if (_blockedApps.isNotEmpty) ...[
          const SizedBox(height: 10),
          _BlockedAppsCards(
            packages: _blockedApps,
            onTapApp: _pickApps,
          ),
        ],
        const SizedBox(height: 22),

        Text('CONTROLS',
            style: TextStyle(fontSize: AppText.overline, color: AppColors.inkFaint, letterSpacing: 0.6)),
        const SizedBox(height: 10),
        _ControlsTile(
          pauseNotifications: _pauseNotifications,
          blockInternet: _blockInternet,
          blockWebsites: _blockWebsites,
          invincible: _invincible,
          blockDoomscroll: _blockDoomscroll,
          onTap: _pickControls,
        ),
        const SizedBox(height: 28),

        _SlideToFocus(
          label: _untimed ? 'Slide to focus · untimed' : 'Slide to focus · $_minutes min',
          busy: _starting,
          onConfirmed: _start,
        ),
      ],
    );
  }

  /// The CONTROLS tile's bottom sheet — every control this session can
  /// enforce, live-toggling the parent's state while the sheet is open.
  Future<void> _pickControls() async {
    await showAppSheet<void>(
      context: context,
      title: 'Session controls',
      subtitle: 'Everything this focus session enforces while it runs',
      builder: (sheetContext, scrollController) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SingleChildScrollView(
          controller: scrollController,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            children: [
              _PolicyToggle(
                icon: AppIconName.userBlock,
                label: 'Block doomscroll apps',
                sublabel: '${kDoomscrollPackages.length} infinite-feed apps — '
                    'TikTok, Instagram, YouTube, X, Reddit…',
                value: _blockDoomscroll,
                onChanged: (v) {
                  setState(() => _blockDoomscroll = v);
                  setSheetState(() {});
                },
              ),
              Divider(height: 1, color: AppColors.stroke),
              _PolicyToggle(
                icon: AppIconName.notificationsOff,
                label: 'Pause notifications',
                value: _pauseNotifications,
                onChanged: (v) {
                  setState(() => _pauseNotifications = v);
                  setSheetState(() {});
                },
              ),
              Divider(height: 1, color: AppColors.stroke),
              _PolicyToggle(
                icon: AppIconName.internet,
                label: 'Block internet',
                value: _blockInternet,
                onChanged: (v) {
                  setState(() => _blockInternet = v);
                  setSheetState(() {});
                },
              ),
              Divider(height: 1, color: AppColors.stroke),
              _PolicyToggle(
                icon: AppIconName.link,
                label: 'Block websites',
                value: _blockWebsites,
                onChanged: (v) {
                  setState(() => _blockWebsites = v);
                  setSheetState(() {});
                },
              ),
              Divider(height: 1, color: AppColors.stroke),
              _PolicyToggle(
                icon: AppIconName.lock,
                label: 'Invincible mode',
                sublabel: 'Ending early requires authentication',
                value: _invincible,
                onChanged: (v) {
                  setState(() => _invincible = v);
                  setSheetState(() {});
                },
              ),
              // Deep link into the doomscroll page: pick platforms,
              // set daily reels/shorts budgets, see the analytics.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: PressableScale(
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.push(Routes.doomscroll);
                  },
                  child: Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(color: AppColors.stroke),
                    ),
                    child: Row(
                      children: [
                        AppIcon(AppIconName.trend, size: 13, color: AppColors.inkDim),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('Doomscroll analytics & budgets',
                              style: TextStyle(
                                  fontSize: 12.5, fontWeight: FontWeight.w600,
                                  color: AppColors.inkDim)),
                        ),
                        AppIcon(AppIconName.chevronRight, size: 12, color: AppColors.inkFaint),
                      ],
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

  Future<void> _pickApps() async {
    final result = await showAppSelector(
      context,
      title: 'Block during focus',
      multiSelect: true,
      initiallySelected: _blockedApps.toSet(),
      selectedFirst: true,
    );
    if (result is Set<String>) {
      setState(() => _blockedApps = result.toList());
    }
  }

  // ---------------------------------------------------------------------
  // Custom tags
  // ---------------------------------------------------------------------

  Future<void> _createTag(BuildContext context) async {
    await showTagEditor(
      context,
      onSave: (name, color) async {
        final id = await ref.read(focusTagsControllerProvider).createTag(name: name, color: color);
        // Select the freshly created tag so the user sees the flow.
        if (mounted) {
          setState(() {
            _selectedTag = FocusTag(
              id: id,
              name: name,
              colorValue: color.toARGB32(),
              createdAt: DateTime.now(),
            );
          });
        }
      },
    );
  }

  Future<void> _editTag(BuildContext context, FocusTag tag) async {
    final controller = ref.read(focusTagsControllerProvider);
    await showTagEditor(
      context,
      tagId: tag.id,
      initialName: tag.name,
      initialColor: Color(tag.colorValue),
      onSave: (name, color) async {
        await controller.renameTag(tag.id, name);
        await controller.recolorTag(tag.id, color);
      },
      onDelete: () async {
        await controller.deleteTag(tag.id);
        if (mounted && _selectedTag?.id == tag.id) {
          setState(() => _selectedTag = null);
        }
      },
    );
  }

  // ---------------------------------------------------------------------
  // Custom duration
  // ---------------------------------------------------------------------

  // Extra minutes for the "custom" chip (may differ from the presets).
  int? _customMinutes;

  String _customLabel() =>
      _customMinutes == null ? 'Custom' : '${_customMinutes!} min';

  Future<void> _pickCustomDuration() async {
    await showAppSheet<int>(
      context: context,
      title: 'Custom duration',
      subtitle: 'Set any length for this session',
      initialSize: 0.65,
      builder: (sheetContext, scrollController) => _CustomDurationSheet(
        initialMinutes: _customMinutes ?? 30,
        onDone: (minutes) {
          setState(() {
            _customMinutes = minutes;
            _minutes = minutes;
            _untimed = false;
          });
          Navigator.of(sheetContext).pop();
        },
      ),
    );
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    try {
      final invincible = _invincible && (await NativePermissions.isBiometricAvailable());
      if (_invincible && invincible) {
        final ok = await NativePermissions.authenticate(
          reason: 'Invincible mode locks this session — confirm to start.',
        );
        if (!ok) {
          setState(() => _starting = false);
          return;
        }
      }
      // Resolve the label: a selected custom tag wins; otherwise the
      // built-in label that is currently selected.
      final label = _selectedTag?.name ?? _selectedBuiltIn;
      final duration = _untimed ? null : Duration(minutes: _minutes);
      // Doomscroll preset unions over the per-platform rules (every
      // managed platform is blocked during a focus session; un-managed
      // platforms stay out of the user's way). Packages not installed
      // are simply never matched by the engine.
      final doomManaged = ref.read(activeDoomscrollPackagesProvider);
      final blocked = _blockDoomscroll
          ? {...kDoomscrollPackages, ...doomManaged, ..._blockedApps}.toList()
          : _blockedApps;
      await ref.read(focusControllerProvider).startSession(
            label: label,
            duration: duration,
            blockedPackages: blocked,
            pauseNotifications: _pauseNotifications,
            blockInternet: _blockInternet,
            blockWebsites: _blockWebsites,
            invincible: invincible,
          );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}

// ---------------------------------------------------------------------------
// Running — timer + policies
// ---------------------------------------------------------------------------

class _RunningFocusView extends ConsumerWidget {
  const _RunningFocusView({required this.session});

  final FocusSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = ref.watch(focusRemainingProvider).valueOrNull ?? Duration.zero;
    final untimed = FocusClock.isUntimed(session);
    final planned = Duration(seconds: session.plannedSeconds);
    final progress = untimed || planned.inSeconds <= 0
        ? 0.0
        : 1 - (remaining.inSeconds / planned.inSeconds).clamp(0.0, 1.0);
    final paused = session.pausedAt != null;

    return RepaintBoundary(
      child: Column(
      children: [
        const SizedBox(height: 24),
        _InvincibleChip(invincible: session.invincible),
        const Spacer(),
        Hero(
          tag: 'focus-timer',
          child: LimitRing(
            progress: progress.clamp(0.0, 1.0),
            size: 220,
            strokeWidth: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!untimed)
                  DurationFlow(
                    remaining,
                    showSeconds: true,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 40,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  )
                else
                  Text(
                    'UNTIMED',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  paused
                      ? '${session.label} · PAUSED'
                      : untimed
                          ? '${session.label} · until you turn it off'
                          : '${session.label} · remaining',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        _PolicySummary(session: session),
        const Spacer(),
        _TodaysSessionsDots(),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => paused
                      ? ref.read(focusControllerProvider).resume()
                      : ref.read(focusControllerProvider).pause(),
                  icon: AppIcon(paused ? AppIconName.play : AppIconName.pause,
                      size: 18, color: AppColors.ink),
                  label: Text(paused ? 'Resume session' : 'Pause session',
                      style: TextStyle(color: AppColors.ink)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(14),
                    backgroundColor: AppColors.surface,
                    side: BorderSide(color: AppColors.stroke),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _confirmEndEarly(context, ref),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(14),
                        minimumSize: const Size(0, 48),
                        backgroundColor: AppColors.surface2,
                        side: BorderSide(color: AppColors.stroke),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                      ),
                      child: Text('End session early', style: TextStyle(color: AppColors.inkDim)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _enterFullScreen(context),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(14),
                        minimumSize: const Size(0, 48),
                        backgroundColor: AppColors.surface2,
                        side: BorderSide(color: AppColors.stroke),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                      ),
                      child: Text('Full screen', style: TextStyle(color: AppColors.inkDim)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
      ),
    );
  }

  /// Distraction-free fullscreen: pushed ABOVE the nav shell as an
  /// opaque route — no swipe, no pill, no status bar (immersive).
  /// Disposing the view restores the system UI.
  void _enterFullScreen(BuildContext context) {
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => _FullScreenFocusView(session: session),
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          child: child,
        ),
      ),
    );
  }

  Future<void> _confirmEndEarly(BuildContext context, WidgetRef ref) =>
      confirmEndFocusSession(context, ref, session);
}

/// End-early confirmation shared by the running view and the fullscreen
/// countdown: confirm (with biometrics for invincible sessions), then
/// end. By default returns to the Focus tab; when [onEnded] is given
/// (fullscreen mode) it is called instead so the caller can pop its
/// own route.
Future<void> confirmEndFocusSession(
    BuildContext context, WidgetRef ref, FocusSession session,
    {VoidCallback? onEnded}) async {
  final confirmed = await showAppSheet<bool>(
    context: context,
    title: 'End session early?',
    subtitle: session.invincible
        ? 'This session is invincible. Ending it early counts as an incomplete session.'
        : 'The session will be recorded as incomplete. Blocked apps are restored immediately.',
    initialSize: 0.45,
    minSize: 0.35,
    builder: (sheetContext, scrollController) => SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppColors.stroke),
                    padding: const EdgeInsets.all(13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: Text('Keep going', style: TextStyle(color: AppColors.ink)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.ink,
                    foregroundColor: AppColors.bg,
                    padding: const EdgeInsets.all(13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: const Text('End session', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  if (confirmed != true) return;

  if (session.invincible) {
    final ok = await NativePermissions.authenticate(reason: 'Confirm to end this invincible session.');
    if (!ok) return;
  }
  await ref.read(focusControllerProvider).endEarly();
  if (onEnded != null) {
    onEnded();
  } else if (context.mounted) {
    context.go('/focus');
  }
}

/// Distraction-free fullscreen countdown: no nav pill, no swipe, no
/// system bars — just the giant centered counter and three pill
/// controls that auto-hide after a few seconds and return on any tap.
/// Landscape by design; entering/exiting manages orientation and the
/// system UI mode, and leaving the route restores both.
class _FullScreenFocusView extends ConsumerStatefulWidget {
  const _FullScreenFocusView({required this.session});

  final FocusSession session;

  @override
  ConsumerState<_FullScreenFocusView> createState() => _FullScreenFocusViewState();
}

class _FullScreenFocusViewState extends ConsumerState<_FullScreenFocusView> {
  static const _autoHideAfter = Duration(seconds: 4);

  Timer? _hideTimer;
  bool _controlsVisible = true;

  @override
  void initState() {
    super.initState();
    // Landscape full-screen clock; status bar + nav bars fully hidden
    // (not sticky-transparent — the display is ours edge to edge).
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _poke() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_autoHideAfter, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _exit() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final remaining = ref.watch(focusRemainingProvider).valueOrNull ?? Duration.zero;
    final untimed = FocusClock.isUntimed(widget.session);
    final paused = widget.session.pausedAt != null;

    return Container(
      color: AppColors.bg,
      // Any touch brings the controls back; they auto-hide again.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _poke,
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The counter — as large as the display allows.
                    // Heading font (Space Grotesk) at the same weight the
                    // app's headings use — no late font swaps.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: untimed
                          ? Text(
                              'UNTIMED',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 180,
                                fontWeight: FontWeight.w600,
                                color: AppColors.ink,
                              ),
                            )
                          : DurationFlow(
                              Duration(seconds: remaining.inSeconds),
                              showSeconds: true,
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 180,
                                fontWeight: FontWeight.w600,
                                color: AppColors.ink,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                    ),
                    if (paused) ...[
                      const SizedBox(height: 10),
                      Text(
                        '${widget.session.label} · PAUSED',
                        style: TextStyle(fontSize: 12, letterSpacing: 1.5, color: AppColors.inkDim),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Three pill controls at the very bottom, auto-hidden.
            AnimatedSlide(
              duration: const Duration(milliseconds: 240),
              curve: _controlsVisible ? Curves.easeOutCubic : Curves.easeInCubic,
              offset: _controlsVisible ? Offset.zero : const Offset(0, 1.2),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 220),
                opacity: _controlsVisible ? 1.0 : 0.0,
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
                    child: Row(
                      children: [
                        Expanded(
                          child: _FullScreenPill(
                            onTap: () => paused
                                ? ref.read(focusControllerProvider).resume()
                                : ref.read(focusControllerProvider).pause(),
                            filled: true,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AppIcon(paused ? AppIconName.play : AppIconName.pause,
                                    size: 14, color: AppColors.bg),
                                const SizedBox(width: 6),
                                Text(
                                  paused ? 'Resume' : 'Pause',
                                  style: TextStyle(
                                      fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.bg),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _FullScreenPill(
                            onTap: () => confirmEndFocusSession(
                              context,
                              ref,
                              widget.session,
                              onEnded: _exit,
                            ),
                            child:
                                Text('End', style: TextStyle(fontSize: 12.5, color: AppColors.inkDim)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _FullScreenPill(
                            onTap: _exit,
                            child: Text('Exit', style: TextStyle(fontSize: 12.5, color: AppColors.inkDim)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the fullscreen view's bottom pills — sized small so the
/// counter owns the screen.
class _FullScreenPill extends StatelessWidget {
  const _FullScreenPill({required this.child, required this.onTap, this.filled = false});

  final Widget child;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? AppColors.ink : AppColors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: filled ? null : Border.all(color: AppColors.stroke),
        ),
        child: child,
      ),
    );
  }
}

class _InvincibleChip extends StatelessWidget {
  const _InvincibleChip({required this.invincible});
  final bool invincible;

  @override
  Widget build(BuildContext context) {
    if (!invincible) return const SizedBox(height: 34);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(AppIconName.lock, size: 12, color: AppColors.inkDim),
          SizedBox(width: 6),
          Text('Invincible mode on', style: TextStyle(fontSize: 11.5, color: AppColors.inkDim)),
        ],
      ),
    );
  }
}

class _PolicySummary extends ConsumerWidget {
  const _PolicySummary({required this.session});
  final FocusSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apps = ref.watch(appsCatalogProvider).valueOrNull;
    String nameFor(String p) => apps?.nameFor(p) ?? p;
    final items = <(String, String)>[
      if (session.blockedPackages.isNotEmpty)
        ('${session.blockedPackages.length} apps blocked',
            session.blockedPackages.map(nameFor).join(' · ')),
      if (session.pauseNotifications) ('Notifications paused', ''),
      if (session.blockInternet) ('Internet blocked', ''),
      if (session.blockWebsites) ('Websites blocked', ''),
    ];

    if (items.isEmpty) {
      return Text('No enforcement policies active',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          for (final (title, detail) in items) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcon(AppIconName.check, size: 12, color: AppColors.inkFaint),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    detail.isEmpty ? title : '$title — $detail',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}

class _TodaysSessionsDots extends ConsumerWidget {
   _TodaysSessionsDots();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(todaysCompletedSessionsProvider).valueOrNull ?? 0;

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
            for (var i = 0; i < count.clamp(0, 12); i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
              ),
            ],
            if (count == 0)
              Text('None yet', style: TextStyle(fontSize: 11, color: AppColors.inkFaint)),
          ],
        ),
      ],
    );
  }
}

/// The trailing "+ New" chip in the SESSION row. Opens the tag editor.
class _NewTagChip extends StatelessWidget {
  const _NewTagChip({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(AppIconName.add, size: 13, color: AppColors.inkDim),
            const SizedBox(width: 6),
            Text(
              'New',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.inkDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "Custom" duration chip — shows the user's own minutes once set.
class _CustomDurationChip extends StatelessWidget {
  const _CustomDurationChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: selected ? null : Border.all(color: AppColors.stroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected ? AppColors.bg : AppColors.inkDim,
              ),
            ),
            const SizedBox(width: 5),
            AppIcon(AppIconName.edit, size: 11, color: selected ? AppColors.bg : AppColors.inkFaint),
          ],
        ),
      ),
    );
  }
}

/// Time-entry sheet for the custom duration chip: a minute stepper plus
/// a text field for exact values (5–720 minutes).
class _CustomDurationSheet extends StatefulWidget {
  const _CustomDurationSheet({
    required this.initialMinutes,
    required this.onDone,
  });

  final int initialMinutes;
  final ValueChanged<int> onDone;

  @override
  State<_CustomDurationSheet> createState() => _CustomDurationSheetState();
}

class _CustomDurationSheetState extends State<_CustomDurationSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: '${widget.initialMinutes}');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int _parseMinutes() {
    final value = int.tryParse(_controller.text.trim());
    if (value == null) return -1;
    return value.clamp(5, 720);
  }

  @override
  Widget build(BuildContext context) {
    final minutes = _parseMinutes();
    final valid = minutes > 0;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          valid
              ? Center(
                  child: DurationFlow(
                    Duration(minutes: minutes),
                    showSeconds: false,
                    style: TextStyle(
                        fontSize: 28, fontWeight: FontWeight.w600, color: AppColors.ink),
                  ),
                )
              : Text(
                  'Enter 5–720 minutes',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: AppColors.ink),
                ),
          const SizedBox(height: 4),
          Row(
            children: [
              // Minutes text field
              Expanded(
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: TextStyle(color: AppColors.ink, fontSize: 14),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Minutes',
                    labelStyle: TextStyle(color: AppColors.inkFaint, fontSize: 12),
                    filled: true,
                    fillColor: AppColors.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Quick stepper
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: IconButton(
                        onPressed: minutes > 5
                            ? () => _controller.text = '${minutes - 5}'
                            : null,
                        icon: Text(
                          '−',
                          style: TextStyle(
                            fontSize: 20,
                            color: AppColors.inkDim,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: IconButton(
                        onPressed: minutes < 720 ? () => _controller.text = '${minutes + 5}' : null,
                        icon: Text(
                          '+',
                          style: TextStyle(
                            fontSize: 20,
                            color: AppColors.inkDim,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: valid ? () => widget.onDone(minutes) : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.ink,
              foregroundColor: AppColors.bg,
              padding: const EdgeInsets.all(13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
            ),
            child: const Text('Set duration', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

class _PolicyToggle extends StatelessWidget {
  const _PolicyToggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.sublabel,
  });

  final AppIconName icon;
  final String label;
  final String? sublabel;
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
            AppIcon(icon, size: 16, color: AppColors.inkDim),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: AppText.body, color: AppColors.ink)),
                  if (sublabel != null) ...[
                    const SizedBox(height: 1),
                    Text(sublabel!, style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint)),
                  ],
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

// ---------------------------------------------------------------------------
// Idle — apps-to-block pill + selected-app cards
// ---------------------------------------------------------------------------

/// The "Block apps" pill in the APPS TO BLOCK row — opens the app
/// picker bottom sheet.
class _AppsPill extends StatelessWidget {
  const _AppsPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(AppIconName.block, size: 13, color: AppColors.inkDim),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.inkDim,
              ),
            ),
            const SizedBox(width: 5),
            AppIcon(AppIconName.chevronDown, size: 11, color: AppColors.inkFaint),
          ],
        ),
      ),
    );
  }
}

/// The selected apps as icon+name cards — at most three fully visible;
/// a longer list scrolls vertically inside the card.
class _BlockedAppsCards extends ConsumerWidget {
  const _BlockedAppsCards({required this.packages, required this.onTapApp});

  final List<String> packages;
  final VoidCallback onTapApp;

  static const _cardHeight = 50.0;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(appsCatalogProvider).valueOrNull;
    String nameFor(String pkg) => catalog?.nameFor(pkg) ?? pkg;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.stroke),
      ),
      // Three cards + two gaps fit; anything beyond scrolls here.
      // (The cap includes the container's own 10px padding on both
      // sides — constraints apply to the outer box.)
      constraints: BoxConstraints(
        maxHeight: 3 * _cardHeight + 2 * _gap + 20,
      ),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          children: [
            for (var i = 0; i < packages.length; i++) ...[
              if (i > 0) const SizedBox(height: _gap),
              _AppBlockCard(
                packageName: packages[i],
                name: nameFor(packages[i]),
                onTap: onTapApp,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One selected app inside the blocked-apps card. Tapping it reopens
/// the picker sheet with the currently selected apps shown first.
class _AppBlockCard extends StatelessWidget {
  const _AppBlockCard({
    required this.packageName,
    required this.name,
    required this.onTap,
  });

  final String packageName;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Row(
          children: [
            AppIconView(packageName: packageName, size: 26, radius: 7),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppText.body, color: AppColors.ink),
              ),
            ),
            AppIcon(AppIconName.chevronDown, size: 12, color: AppColors.inkFaint),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Idle — CONTROLS tile
// ---------------------------------------------------------------------------

/// The CONTROLS tile: a summary of what this session will enforce.
/// Tapping opens the bottom sheet with every control as a switch.
class _ControlsTile extends StatelessWidget {
  const _ControlsTile({
    required this.pauseNotifications,
    required this.blockInternet,
    required this.blockWebsites,
    required this.invincible,
    required this.blockDoomscroll,
    required this.onTap,
  });

  final bool pauseNotifications;
  final bool blockInternet;
  final bool blockWebsites;
  final bool invincible;
  final bool blockDoomscroll;
  final VoidCallback onTap;

  String get _summary {
    final active = <String>[
      if (blockDoomscroll) 'Doomscroll blocked',
      if (pauseNotifications) 'Notifications paused',
      if (blockInternet) 'Internet blocked',
      if (blockWebsites) 'Websites blocked',
      if (invincible) 'Invincible',
    ];
    if (active.isEmpty) return 'Nothing extra — tap to configure';
    return active.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Row(
          children: [
            AppIcon(AppIconName.shield, size: 16, color: AppColors.inkDim),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Controls',
                      style: TextStyle(fontSize: AppText.body, color: AppColors.ink)),
                  const SizedBox(height: 2),
                  Text(
                    _summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: AppColors.inkFaint),
                  ),
                ],
              ),
            ),
            AppIcon(AppIconName.chevronRight, size: 13, color: AppColors.inkFaint),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Idle — slide-to-focus button
// ---------------------------------------------------------------------------

/// Slide-to-start control: a big horizontal pill with a draggable knob.
/// Drag it to the right edge to start the session; release early and it
/// springs back. Replaces a plain tap button so starting a session is a
/// deliberate gesture.
class _SlideToFocus extends StatefulWidget {
  const _SlideToFocus({
    required this.label,
    required this.onConfirmed,
    this.busy = false,
  });

  final String label;
  final VoidCallback onConfirmed;
  final bool busy;

  @override
  State<_SlideToFocus> createState() => _SlideToFocusState();
}

class _SlideToFocusState extends State<_SlideToFocus> {
  // 0..1 — how far the knob has travelled across the track.
  double _progress = 0;
  bool _dragging = false;

  static const _hPadding = 6.0;
  static const _knobSize = 50.0;
  static const _height = 62.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final track = constraints.maxWidth - 2 * _hPadding - _knobSize;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: widget.busy ? null : (_) => _dragging = true,
          onHorizontalDragUpdate: widget.busy
              ? null
              : (d) => setState(() {
                    _progress = (_progress + d.delta.dx / track).clamp(0.0, 1.0);
                  }),
          onHorizontalDragEnd: widget.busy ? null : (_) => _release(),
          onHorizontalDragCancel: widget.busy ? null : () => _release(),
          child: Container(
            height: _height,
            padding: const EdgeInsets.symmetric(horizontal: _hPadding),
            decoration: BoxDecoration(
              color: AppColors.ink,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Label — fades out as the knob approaches the end.
                IgnorePointer(
                  child: Opacity(
                    opacity: (1 - _progress * 1.6).clamp(0.0, 1.0),
                    child: widget.busy
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.bg),
                          )
                        : Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppText.body,
                              fontWeight: FontWeight.w600,
                              color: AppColors.bg,
                            ),
                          ),
                  ),
                ),
                // The knob.
                Align(
                  alignment: Alignment(-1 + 2 * _progress, 0),
                  child: AnimatedScale(
                    scale: _dragging ? 1.06 : 1.0,
                    duration: const Duration(milliseconds: 140),
                    child: Container(
                      width: _knobSize,
                      height: _knobSize,
                      decoration: BoxDecoration(
                        color: AppColors.bg,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: _progress > 0.9
                            ? AppIcon(AppIconName.check, size: 20, color: AppColors.ink)
                            : AppIcon(AppIconName.play, size: 20, color: AppColors.ink),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _release() {
    _dragging = false;
    final confirmed = _progress >= 0.92;
    setState(() => _progress = 0);
    if (confirmed) widget.onConfirmed();
  }
}
