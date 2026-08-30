import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/icons/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/router/app_router.dart';

class NavShell extends StatelessWidget {
  const NavShell({super.key, required this.child});
  final Widget child;

  static const _tabs = [
    (Routes.home, AppIconName.home, 'Home'),
    (Routes.focus, AppIconName.focus, 'Focus'),
    (Routes.limits, AppIconName.limits, 'Limits'),
    (Routes.bedtime, AppIconName.bedtime, 'Bedtime'),
    (Routes.settings, AppIconName.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;

    final activeIndex = _tabs.indexWhere((t) => t.$1 == location).clamp(0, 4);

    void goToTab(int index) {
      if (index < 0 || index >= _tabs.length || index == activeIndex) return;
      context.go(_tabs[index].$1);
    }

    return Scaffold(
      // `child` is the current tab's screen; Stack lets the nav float
      // over it without stealing layout space, matching the mockup.
      body: Stack(
        children: [
          GestureDetector(
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
            child: child,
          ),
          Positioned(
            left: 16,
            right: 16,
            // Clear the gesture-navigation inset so the pill floats
            // above it rather than colliding with the system bar.
            bottom: MediaQuery.paddingOf(context).bottom + 16,
            child: _FloatingNavBar(
              tabs: _tabs,
              activeIndex: activeIndex,
              onTap: goToTab,
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
