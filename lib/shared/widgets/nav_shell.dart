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
              routeIndex: routeIndex,
              pageController: _pageController,
              pillPosition: _pillPosition,
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
    required this.routeIndex,
    required this.pageController,
    required this.pillPosition,
    required this.glide,
    required this.visible,
    required this.onTap,
  });

  final List<(String, AppIconName, String)> tabs;
  final int routeIndex;
  final PageController pageController;

  /// Current on-screen highlight position in page units (recomputed by
  /// the shell on every glide tick and page tick).
  final double Function() pillPosition;
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
              // The shell recomputes pillPosition per glide tick; the
              // page controller ticks drive the swipe tracking.
              animation: Listenable.merge([pageController, glide]),
              builder: (context, _) {
                final page = pageController.hasClients
                    ? (pageController.page ?? routeIndex.toDouble())
                    : routeIndex.toDouble();
                return _FloatingNavBar(
                  tabs: tabs,
                  pillPosition: pillPosition(),
                  page: page,
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

/// The floating pill bar with one CONTINUOUS ink highlight: it glides
/// with the live page position during swipes (finger 1:1, like an iOS
/// segmented control) and, on nav-item taps, glides to the destination
/// while the page jumps underneath — one motion, no teleporting.
class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.tabs,
    required this.pillPosition,
    required this.page,
    required this.onTap,
  });

  final List<(String, AppIconName, String)> tabs;

  /// Highlight position in page units (glide-aware, from the shell).
  final double pillPosition;

  /// Live page value — drives the icon/label state flip.
  final double page;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final activeIndex = page.round().clamp(0, tabs.length - 1);
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
      child: LayoutBuilder(builder: (context, constraints) {
        // Inside the 8px padding each tab slot is an exact fifth.
        final slotWidth = constraints.maxWidth / tabs.length;
        return SizedBox(
          height: 38,
          child: Stack(
            children: [
              // The gliding ink highlight behind the items.
              Positioned(
                left: slotWidth * pillPosition.clamp(0.0, tabs.length - 1.0),
                width: slotWidth,
                top: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.ink,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
              ),
              // Hit targets + icons/labels on top.
              Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Expanded(
                      child: _NavItem(
                        icon: tabs[i].$2,
                        label: tabs[i].$3,
                        isActive: i == activeIndex,
                        onTap: () => onTap(i),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// The nav item: icon (+ label when active), drawn ON TOP of the
/// gliding ink highlight — the item paints no background of its own so
/// the highlight can slide freely underneath.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final AppIconName icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              icon,
              size: 19,
              color: isActive ? AppColors.bg : AppColors.inkDim,
            ),
            // AnimatedSize + fade avoids laying out invisible text every
            // frame for the inactive tabs — cheaper than always building
            // the label and toggling opacity to zero.
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: isActive
                  ? Padding(
                      padding: const EdgeInsets.only(left: 7, right: 3),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.bg,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
