import 'package:flutter/material.dart';

/// A cheap "morph" transition: cross-fade + slight scale-and-lift, tuned
/// to feel like the app icon/ring language morphing between screens
/// rather than a generic slide.
///
/// Deliberately avoids: Transform.rotate (forces a full repaint each
/// frame at odd matrices), BackdropFilter blur during motion (GPU-heavy,
/// causes jank on mid-range Android), and Hero animations chained across
/// more than one flight (janky on complex subtrees like the ring SVGs).
/// FadeTransition + ScaleTransition alone stay on the compositor thread.
class MorphPage<T> extends PageRouteBuilder<T> {
  MorphPage({required this.child, super.settings})
      : super(
          transitionDuration: const Duration(milliseconds: 260),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          opaque: true,
          pageBuilder: (context, animation, secondaryAnimation) => child,
          transitionsBuilder: (context, animation, secondaryAnimation, page) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween(begin: 0.97, end: 1.0).animate(curved),
                child: child,
              ),
            );
          },
        );

  final Widget child;
}

/// Directional tab transition: the incoming screen slides in from the
/// side matching the navigation direction — right when moving to a
/// higher tab, left when moving back — with a soft fade on top, so a
/// tab switch reads as a physical swipe between adjacent pages rather
/// than a dissolve.
///
/// `direction` is +1 (forward) or -1 (back); NavShell tracks the tab
/// order delta and Routes carries it to the router.
Widget tabSlide(Widget child, Animation<double> animation, double direction) {
  final curved = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  return SlideTransition(
    position: Tween<Offset>(
      begin: Offset(0.30 * direction, 0),
      end: Offset.zero,
    ).animate(curved),
    child: FadeTransition(
      opacity: Tween<double>(begin: 0.55, end: 1.0).animate(curved),
      child: child,
    ),
  );
}
