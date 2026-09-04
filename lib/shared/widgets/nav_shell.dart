import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/icons/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/router/app_router.dart';
import '../../data/providers.dart';
import '../../features/bedtime/bedtime_screen.dart';
import '../../features/focus/focus_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/limits/limits_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../shared/widgets/app_sheet.dart';

/// The app's navigation shell. Owns the global navigation behaviors:
///
///  1. Horizontal swipe between the five primary destinations. The
///     PageView tracks the finger 1:1 — no fade, no cross-dissolve;
///     the destination page follows the drag directly.
///  2. The floating pill's selection follows the swipe gesture too
///     (nearest page while dragging), and hides while scrolling a page
///     vertically downward and while any overlay (sheet/dialog/detail
///     route) is open.
///  3. Constant status-bar top spacing (native, stable — no
///     scroll-coupled layout changes, which caused jitter).
class NavShell extends ConsumerStatefulWidget {
  const NavShell({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<NavShell> createState() => _NavShellState();
}

class _NavShellState extends ConsumerState<NavShell>
    with SingleTickerProviderStateMixin {
  static const _tabs = [
    (Routes.home, AppIconName.home, 'Home'),
    (Routes.focus, AppIconName.focus, 'Focus'),
    (Routes.limits, AppIconName.limits, 'Limits'),
    (Routes.bedtime, AppIconName.bedtime, 'Bedtime'),
    (Routes.settings, AppIconName.settings, 'Settings'),
  ];

  // The five primary destinations, constructed DIRECTLY ONCE per shell
  // state lifetime and memoized: the PageView owns them and the
  // go_router location only STEERS the controller. The shell's routed
  // `child` is intentionally not mounted — mounting it inside a
  // swiping PageView would duplicate the active screen.
  //
  // Stable instances matter: without this, every rebuild of this State
  // (route change, pill tap, provider emit) recreated all five screens
  // from scratch, and since each screen State is keep-alived the widget
  // diff still forced a full rebuild of Home's 18-provider tree, the
  // charts' paintings and the Settings collapsibles — a multi-second
  // stall on low-end hardware. Theme changes still propagate: they flow
  // through inherited widgets (Theme.of), not through instance identity.
  late final List<Widget> _screens = [
    HomeScreen(),
    FocusScreen(),
    LimitsScreen(),
    BedtimeScreen(),
    SettingsScreen(),
  ];

  Widget _screen(int index) => _screens[index];

  late final PageController _pageController;
  bool _navVisible = true;
  int _lastRouteIndex = -1;

  /// Drives the nav highlight's glide: taps JUMP the page instantly
  /// (no intermediate screen is ever built) but the ink pill glides to
  /// the destination with an iOS-like ease, so the switch still reads
  /// as one motion. Swipes bypass this — the highlight rides the
  /// finger via the page position.
  late final AnimationController _glide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  double _glideFrom = 0;
  double _glideTo = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _glide.addStatusListener((status) {
      if (status == AnimationStatus.completed) setState(() {});
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _glide.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    // The PageView's own horizontal drags must not toggle the pill.
    if (n.metrics.axis != Axis.vertical) return false;

    if (n is UserScrollNotification) {
      switch (n.direction) {
        case ScrollDirection.reverse:
          if (_navVisible) setState(() => _navVisible = false);
        case ScrollDirection.forward:
          if (!_navVisible) setState(() => _navVisible = true);
        case ScrollDirection.idle:
          break;
      }
    }
    return false;
  }

  // True when the coming location change was initiated by a NAV-ITEM
  // TAP: the PageView must JUMP to the destination without sliding
  // through intermediate tabs (each keep-alive screen's heavy subtree
  // would be built along the way — the multi-second freeze). Set by
  // goToTab (a tap callback) and consumed on the next route-change
  // build; swipes never set it, so they keep their slide behavior.
  bool _jumpOnNextRouteChange = false;

  /// Current on-screen highlight position in page units: glides toward
  /// its target while a tap-driven glide plays, otherwise tracks the
  /// live page value (finger 1:1).
  double _pillPosition() {
    if (_glide.isAnimating) {
      final t = Curves.easeOutCubic.transform(_glide.value);
      return _glideFrom + (_glideTo - _glideFrom) * t;
    }
    return _pageController.hasClients
        ? (_pageController.page ?? _lastRouteIndex.clamp(0, _tabs.length - 1).toDouble())
        : _lastRouteIndex.clamp(0, _tabs.length - 1).toDouble();
  }

  /// Per-slot morph factor (0..1): 1 = fully expanded (icon + label),
  /// 0 = icon-only. A pure function of the highlight position, so slot
  /// widths, ink geometry and content always agree — nothing can lag
  /// or drift out of center.
  List<double> _morphFactors() {
    final n = _tabs.length;
    final m = List<double>.filled(n, 0);
    if (_glide.isAnimating) {
      // Tap glide: the origin slot collapses and the destination
      // expands with the same eased progress as the ink's travel —
      // intermediate slots stay icon-only, so no label ever flashes.
      final e = Curves.easeOutCubic.transform(_glide.value);
      final a = _glideFrom.round().clamp(0, n - 1);
      final b = _glideTo.round().clamp(0, n - 1);
      m[a] = 1 - e;
      m[b] = e;
    } else if (_pageController.hasClients) {
      // Swipe: factors ride the page value — the leaving slot folds
      // while the arriving one unfolds under the finger.
      final page = _pageController.page ?? _lastRouteIndex.clamp(0, n - 1).toDouble();
      for (var i = 0; i < n; i++) {
        m[i] = (1.0 - (page - i).abs()).clamp(0.0, 1.0);
      }
    } else {
      m[_lastRouteIndex.clamp(0, n - 1)] = 1;
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final routeIndex = _tabs.indexWhere((t) => t.$1 == location).clamp(0, _tabs.length - 1);

    // "Hide Nav Bar" setting: immersive mode — no floating pill at all.
    final hideNavBar = ref.watch(hideNavBarProvider).valueOrNull ?? false;

    // Physical navigation: deep link / initial route / a go() that did
    // NOT come from a PageView gesture or nav-item tap. The PageView
    // must be steered to match.
    if (_lastRouteIndex == -1) {
      _lastRouteIndex = routeIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients && _pageController.page?.round() != routeIndex) {
          _pageController.jumpToPage(routeIndex);
        }
      });
    } else if (routeIndex != _lastRouteIndex &&
        (!_pageController.hasClients || _pageController.page?.round() != routeIndex)) {
      if (_jumpOnNextRouteChange) {
        // Nav-item tap: direct jump — the page change is instant and no
        // intermediate screen is ever built or laid out. The ink pill
        // covers the jump with its glide. Deferred past the build
        // phase: jumpToPage in build() would fire onPageChanged
        // synchronously mid-build (and therefore context.go mid-build),
        // corrupting the router. Post-frame it is equivalent, and a tap
        // is always post-frame anyway.
        final target = routeIndex;
        _glideFrom = _pillPosition();
        _glideTo = target.toDouble();
        if ((_glideTo - _glideFrom).abs() > 0.001) {
          _glide.forward(from: 0);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageController.hasClients) _pageController.jumpToPage(target);
        });
      } else {
        // Swipe/route-driven: slide through pages naturally.
        _pageController.animateToPage(
          routeIndex,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    }
    _jumpOnNextRouteChange = false;
    _lastRouteIndex = routeIndex;

    void goToTab(int index) {
      if (index < 0 || index >= _tabs.length || index == routeIndex) return;
      // Nav-item tap: mark the next route change as a JUMP so build()
      // offsets its PageView steering instead of sliding through the
      // intermediate screens.
      _jumpOnNextRouteChange = true;
      context.go(_tabs[index].$1);
    }

    return Scaffold(
      // Let the page background and scrolling content extend behind the
      // floating-pill strip: the nav strip's own area is transparent (see
      // _FloatingNavContainer) so the main page shows through it, while
      // the pill itself keeps its opaque surface. In "Hide Nav Bar"
      // immersive mode there is no strip at all — the body simply spans
      // the full screen.
      extendBody: !hideNavBar,
      // iOS sheet presentation: the page zooms out (scales down with
      // rounded corners) while any bottom sheet is open. The nav pill
      // stays outside the zoom — it hides itself while overlays are
      // open anyway.
      body: SheetZoom(
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Padding(
            // Constant status-bar spacing — stable, native, no
            // scroll-coupled layout changes.
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            child: PageView.builder(
              controller: _pageController,
              itemCount: _tabs.length,
              onPageChanged: (page) {
                // Keep the router location in sync with the gesture.
                if (_tabs[page].$1 != location) {
                  context.go(_tabs[page].$1);
                }
              },
              itemBuilder: (context, i) => _TabKeepAlive(child: _screen(i)),
            ),
          ),
        ),
      ),
      // Floating nav pill — hidden while scrolling down or while any
      // overlay is open; selection follows the swipe gesture live.
      // Omitted entirely in "Hide Nav Bar" immersive mode.
      bottomNavigationBar: hideNavBar
          ? null
          : _FloatingNavContainer(
              tabs: _tabs,
              pageController: _pageController,
              pillPosition: _pillPosition,
              morph: _morphFactors,
              glide: _glide,
              visible: _navVisible,
              onTap: goToTab,
            ),
    );
  }
}

/// Keeps visited tab pages alive so navigation state (scroll positions,
/// form state) survives switching — without keep-alive the PageView
/// would dispose every page that scrolls out of view.
class _TabKeepAlive extends StatefulWidget {
  const _TabKeepAlive({required this.child});
  final Widget child;

  @override
  State<_TabKeepAlive> createState() => _TabKeepAliveState();
}

class _TabKeepAliveState extends State<_TabKeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Anchors the floating pill above the gesture inset, hides it while
/// overlays are open or the user scrolls down, and animates selection
/// during swipes.
class _FloatingNavContainer extends StatelessWidget {
  const _FloatingNavContainer({
    required this.tabs,
    required this.pageController,
    required this.pillPosition,
    required this.morph,
    required this.glide,
    required this.visible,
    required this.onTap,
  });

  final List<(String, AppIconName, String)> tabs;
  final PageController pageController;

  /// Current on-screen highlight position in page units (recomputed by
  /// the shell on every glide tick and page tick).
  final double Function() pillPosition;

  /// Per-slot expansion factors (recomputed by the shell on every tick
  /// — the SAME function that drives the ink, so content and highlight
  /// can never drift apart).
  final List<double> Function() morph;
  final Animation<double> glide;
  final bool visible;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      // Reserve layout space so page content is never overlapped by the
      // pill — cleaner than floating over text, and no shadow jank.
      padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.paddingOf(context).bottom + 12),
      color: Colors.transparent,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, 1.6),
        duration: const Duration(milliseconds: 240),
        curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedBuilder(
              // Glide ticks (tap-driven ink travel) + page ticks
              // (swipes) both refresh the morph factors and position.
              animation: Listenable.merge([pageController, glide]),
              builder: (context, _) {
                return _FloatingNavBar(
                  tabs: tabs,
                  pillPosition: pillPosition(),
                  morph: morph(),
                  onTap: onTap,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The floating pill bar where the ink highlight and the item slots are
/// computed from the SAME per-slot morph factors. Each slot's width is
///
///   idleWidth + (activeWidth_i - idleWidth) * m_i
///
/// — icon-only when collapsed, icon + gap + label + symmetric padding
/// when expanded — and the whole row is normalized to fill the capsule
/// exactly, so the ink pill and the item centers can never drift apart.
/// Every frame is one continuous interpolation: swipes ride the finger,
/// taps glide while slots resize in lockstep.
// Nav bar geometry (dp). All slots share one fixed height — only
// widths redistribute, so the bar never changes height and nothing
// overlaps.
const double _kNavItemHeight = 38.0;
const double _kNavIconSize = 20.0;
const double _kNavIconGap = 8.0; // icon → label gap inside the active item
const double _kNavItemPadH = 14.0; // ink pill horizontal padding
const double _kNavLabelFontSize = 12.0;
const double _kNavIdleSlotWidth = 46.0; // 13 + icon 20 + 13

/// Width budget for the revealed label — sized for the longest label at
/// scale 1.0 and multiplied by the device text scaler so bigger system
/// text gets a proportionally wider active slot.
const double _kNavLabelBudget = 64.0;

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.tabs,
    required this.pillPosition,
    required this.morph,
    required this.onTap,
  });

  final List<(String, AppIconName, String)> tabs;

  /// Highlight position in page units (glide-aware, from the shell).
  final double pillPosition;

  /// Per-slot expansion factors, 0 (icon-only) → 1 (icon + label).
  final List<double> morph;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final x = pillPosition.clamp(0.0, tabs.length - 1.0);
    final m = morph;

    // The label budget follows the device text scale, so the expanded
    // slot always has room for the real rendered text — the label
    // itself lays out at its NATURAL width (no measurement, no
    // clipping) and is revealed with a width factor + fade.
    final fontScale =
        MediaQuery.textScalerOf(context).scale(_kNavLabelFontSize) / _kNavLabelFontSize;
    final activeSlot =
        _kNavIconSize + _kNavIconGap + _kNavLabelBudget * fontScale + 2 * _kNavItemPadH;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.stroke),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: SizedBox(
        height: _kNavItemHeight,
        child: LayoutBuilder(builder: (context, constraints) {
          // Raw slot widths: idle blended toward the expanded measure
          // by each slot's morph factor.
          final raw = [
            for (var i = 0; i < tabs.length; i++)
              _kNavIdleSlotWidth +
                  (activeSlot - _kNavIdleSlotWidth) * (m[i].clamp(0.0, 1.0)),
          ];

          // Normalize so the row fills the capsule EXACTLY — item
          // centers and the ink geometry are computed from these same
          // numbers, which is what keeps them locked together.
          final rawSum = raw.fold(0.0, (a, b) => a + b);
          final widths = [for (final w in raw) w * constraints.maxWidth / rawSum];

          // Ink geometry: walk the normalized slot boundaries to the
          // fractional highlight position; the ink's left edge and
          // width interpolate across the boundary in one motion.
          final leftIndex = x.floor().clamp(0, tabs.length - 1);
          final frac = (x - leftIndex).clamp(0.0, 1.0);
          final leftEdge = widths.sublist(0, leftIndex).fold(0.0, (a, b) => a + b);
          final nextIndex = (leftIndex + 1).clamp(0, tabs.length - 1);
          final inkLeft = leftEdge + widths[leftIndex] * frac;
          final inkWidth = widths[leftIndex] * (1 - frac) + widths[nextIndex] * frac;

          return Stack(
            children: [
              // The gliding ink highlight behind the items.
              Positioned(
                left: inkLeft,
                width: inkWidth,
                top: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.ink,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
              ),
              // Hit targets + icons/labels on top, laid out with the
              // same normalized widths as the ink underneath.
              Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    SizedBox(
                      width: widths[i],
                      height: _kNavItemHeight,
                      child: _NavItem(
                        icon: tabs[i].$2,
                        label: tabs[i].$3,
                        reveal: m[i].clamp(0.0, 1.0),
                        onTap: () => onTap(i),
                      ),
                    ),
                ],
              ),
            ],
          );
        }),
      ),
    );
  }
}

/// The nav item: icon + width-revealed label, centered in its slot —
/// the same slot the ink covers, so content is always centered on the
/// highlight.
///
/// The label lays out at its NATURAL width (no measurement, no
/// clipping — immune to theme fonts and device text scale) and is
/// revealed by [Align]'s `widthFactor` + fade, both driven by the same
/// continuous [reveal] factor that drives the slot width and the ink.
/// A FittedBox guard scales the whole content down if a huge device
/// text scale would ever exceed the slot.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.reveal,
    required this.onTap,
  });

  final AppIconName icon;
  final String label;

  /// 0 = icon-only, 1 = icon + label fully revealed.
  final double reveal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = reveal.clamp(0.0, 1.0);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                icon,
                size: _kNavIconSize,
                color: Color.lerp(AppColors.inkDim, AppColors.bg, t),
              ),
              // The label wipes out from behind the icon: Align's
              // widthFactor grows with the reveal factor, ClipRect
              // masks the still-hidden part.
              ClipRect(
                child: Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: t,
                  child: Opacity(
                    opacity: t,
                    child: Padding(
                      padding: const EdgeInsets.only(left: _kNavIconGap),
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: _kNavLabelFontSize,
                          fontWeight: FontWeight.w600,
                          color: AppColors.bg,
                        ),
                      ),
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

