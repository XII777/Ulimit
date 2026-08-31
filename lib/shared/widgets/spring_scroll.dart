import 'package:flutter/material.dart';

/// The app's one scroll feel: iOS-style bounce with the platform's
/// natural deceleration — glides to a stop instead of snapping, and
/// overscroll bounces back softly (BouncingScrollPhysics' overscroll
/// response matches what Cupertino pages feel like). Widgets that need
/// a harder Android clamp can override with ClampingScrollPhysics
/// directly.
const ScrollPhysics springScrollPhysics =
    BouncingScrollPhysics(decelerationRate: ScrollDecelerationRate.normal);
