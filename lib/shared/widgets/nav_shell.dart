import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:go_router/go_router.dart';
import '../../core/icons/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/router/app_router.dart';

/// The app's navigation shell. Owns three global behaviors:
///
///  1. Tab-direction tracking for the swipe transition (writes
///     [Routes.tabDirection] before the transition's first frame).
///  2. The collapsing top inset: pages start offset below the status
///     bar; scrolling pulls that offset to zero so content expands to
///     full height.
///  3. Hide-on-scroll-down / show-on-scroll-up for the floating pill.
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

  late double _statusBarHeight;
  late final ValueNotifier<double> _topInset;
  bool _navVisible = true;
  int _lastIndex = -1;

  @override
  void initState() {
    super.initState();
    // The real height is assigned on first build (MediaQuery isn't
    // available in initState); 24 is a sane pre-build default.
    _topInset = ValueNotifier<double>(24);
  }

  @override
  void dispose() {
    _topInset.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;

    // Collapse the top inset as content scrolls up past the status bar.
    final inset = math.max(0.0, _statusBarHeight - n.metrics.pixels);
    if ((_topInset.value - inset).abs() > 0.5) {
      _topInset.value = inset;
    }

    // Hide the pill on downward scrolling, reveal on upward scrolling.
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
    final activeIndex = _tabs.indexWhere((t) => t.$1 == location).clamp(0, _tabs.length - 1);

    // First build: capture the real system top inset and seed both the
    // collapsing inset and the direction tracker.
    _statusBarHeight = MediaQuery.paddingOf(context).top;
    if (_lastIndex == -1) {
      _topInset.value = _statusBarHeight;
      Routes.lastTabIndex = activeIndex;
    }
    if (activeIndex != Routes.lastTabIndex) {
      Routes.tabDirection = activeIndex > Routes.lastTabIndex ? 1.0 : -1.0;
      Routes.lastTabIndex = activeIndex;
      // A fresh tab starts at its top: restore the inset and show the
      // pill so the new page never opens with a hidden nav bar.
      _topInset.value = _statusBarHeight;
      if (!_navVisible) _navVisible = true;
    }

    void goToTab(int index) {
      if (index < 0 || index >= _tabs.length || index == activeIndex) return;
      context.go(_tabs[index].$1);
    }

    return Scaffold(
      body: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: ValueListenableBuilder<double>(
              valueListenable: _topInset,
              // `child` is passed through untouched — scroll-driven inset
              // updates rebuild only this Padding, never the tab page.
              builder: (context, inset, page) =>
                  Padding(padding: EdgeInsets.only(top: inset), child: page),
              child: GestureDetector(
                // A horizontal-only gesture recognizer would still fire on
                // primarily-vertical drags; gating on velocity magnitude in
                // onHorizontalDragEnd (rather than onHorizontalDragUpdate)
                // means this only acts on a deliberate, fast horizontal
                // flick, so normal vertical scrolling on any tab's content
                // is never intercepted or fights with this gesture.
                onHorizontalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  const threshold = 300.0;
                  if (velocity < -threshold) {
                    goToTab(activeIndex + 1);
                  } else if (velocity > threshold) {
                    goToTab(activeIndex - 1);
                  }
                },
                child: widget.child,
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            // Clear the gesture-navigation inset so the pill floats
            // above it rather than colliding with the system bar.
            bottom: MediaQuery.paddingOf(context).bottom + 16,
            child: AnimatedSlide(
              // Hidden while scrolling down, revealed on scroll up.
              offset: _navVisible ? Offset.zero : const Offset(0, 1.4),
              duration: const Duration(milliseconds: 240),
              curve: _navVisible ? Curves.easeOutCubic : Curves.easeInCubic,
              child: AnimatedOpacity(
                opacity: _navVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  // A hidden pill must not eat taps meant for content.
                  ignoring: !_navVisible,
                  child: _FloatingNavBar(
                    tabs: _tabs,
                    activeIndex: activeIndex,
                    onTap: goToTab,
                  ),
                ),
              ),
            ),
          ),
        ],
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
        color: const Color(0xFF0B0C10),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.stroke),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.55),
            blurRadius: 30,
            offset: const Offset(0, 14),
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
                  color: isActive ? AppColors.bg : AppColors.inkFaint,
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
                        style: const TextStyle(
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
