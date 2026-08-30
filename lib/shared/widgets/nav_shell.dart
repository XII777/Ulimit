import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:go_router/go_router.dart';
import '../../core/icons/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/router/app_router.dart';
import '../../features/bedtime/bedtime_screen.dart';
import '../../features/focus/focus_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/limits/limits_screen.dart';
import '../../features/settings/settings_screen.dart';
import 'app_sheet.dart';

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
class NavShell extends StatefulWidget {
  const NavShell({super.key, required this.child});
  final Widget child;

  @override
  State<NavShell> createState() => _NavShellState();
}

class _NavShellState extends State<NavShell> {
  static const _tabs = [
    (Routes.home, AppIconName.home, 'Home'),
    (Routes.focus, AppIconName.focus, 'Focus'),
    (Routes.limits, AppIconName.limits, 'Limits'),
    (Routes.bedtime, AppIconName.bedtime, 'Bedtime'),
    (Routes.settings, AppIconName.settings, 'Settings'),
  ];

  // The five primary destinations, constructed directly: the PageView
  // owns them, and the go_router location only STEERS the controller.
  // The shell's routed `child` is intentionally not mounted — mounting
  // it inside a swiping PageView would duplicate the active screen.
  static const _screens = [
    HomeScreen(),
    FocusScreen(),
    LimitsScreen(),
    BedtimeScreen(),
    SettingsScreen(),
  ];

  late final PageController _pageController;
  bool _navVisible = true;
  int _lastRouteIndex = -1;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
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

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final routeIndex = _tabs.indexWhere((t) => t.$1 == location).clamp(0, _tabs.length - 1);

    // A location change that did NOT come from the PageView itself
    // (deep link, initial load) must drag the PageView to match.
    if (_lastRouteIndex == -1) {
      _lastRouteIndex = routeIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients && _pageController.page?.round() != routeIndex) {
          _pageController.jumpToPage(routeIndex);
        }
      });
    } else if (routeIndex != _lastRouteIndex &&
        (!_pageController.hasClients || _pageController.page?.round() != routeIndex)) {
      _pageController.animateToPage(
        routeIndex,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
    _lastRouteIndex = routeIndex;

    void goToTab(int index) {
      if (index < 0 || index >= _tabs.length || index == routeIndex) return;
      context.go(_tabs[index].$1);
    }

    return Scaffold(
      body: NotificationListener<ScrollNotification>(
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
            itemBuilder: (context, i) => _TabKeepAlive(child: _screens[i]),
          ),
        ),
      ),
      // Floating nav pill — hidden while scrolling down or while any
      // overlay is open; selection follows the swipe gesture live.
      bottomNavigationBar: _FloatingNavContainer(
        tabs: _tabs,
        routeIndex: routeIndex,
        pageController: _pageController,
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
    required this.visible,
    required this.onTap,
  });

  final List<(String, AppIconName, String)> tabs;
  final int routeIndex;
  final PageController pageController;
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
              animation: pageController,
              builder: (context, _) {
                // Selection follows the swipe gesture: the nearest page
                // while dragging, the settled page when idle.
                final page = pageController.hasClients ? (pageController.page ?? 0.0) : routeIndex.toDouble();
                final activeIndex = page.round().clamp(0, tabs.length - 1);
                return _FloatingNavBar(
                  tabs: tabs,
                  activeIndex: activeIndex,
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

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.tabs,
    required this.activeIndex,
    required this.onTap,
  });

  final List<(String, AppIconName, String)> tabs;
  final int activeIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(tabs.length, (i) {
          final isActive = i == activeIndex;
          final (_, icon, label) = tabs[i];
          return _NavItem(
            icon: icon,
            label: label,
            isActive: isActive,
            onTap: () => onTap(i),
          );
        }),
      ),
    );
  }
}

/// The morph: an AnimatedContainer widens from an icon-only circle into
/// an icon+label pill. AnimatedContainer is the right tool here — it's
/// implicitly driven by the widget tree diff, so there's no
/// AnimationController to leak or forget to dispose, and Flutter batches
/// the size/color tween into a single compositor-friendly pass.
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        height: 38,
        padding: EdgeInsets.symmetric(horizontal: isActive ? 14 : 0),
        decoration: BoxDecoration(
          color: isActive ? AppColors.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 38,
              child: Center(
                child: AppIcon(
                  icon,
                  size: 19,
                  color: isActive ? AppColors.bg : AppColors.inkDim,
                ),
              ),
            ),
            // AnimatedSize + fade avoids laying out invisible text every
            // frame for the four inactive tabs — cheaper than always
            // building the label and toggling opacity to zero.
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: isActive
                  ? Padding(
                      padding: const EdgeInsets.only(right: 2),
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
