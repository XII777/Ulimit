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

/// For bottom-nav tab switches specifically: no fade-through-black,
/// just a fast cross-dissolve so tapping Home→Focus→Limits feels
/// instant, not like navigating "into" a new page.
Widget tabMorph(Widget child, Animation<double> animation) {
  return FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  );
}
