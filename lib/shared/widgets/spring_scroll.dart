import 'package:flutter/material.dart';

/// The app's one scroll feel: the platform's native physics
/// (ClampingScrollPhysics with the Android stretch effect), so vertical
/// scrolling reads exactly like every other Android app — smooth,
/// predictable, no bouncing transformations.
const ScrollPhysics springScrollPhysics = ClampingScrollPhysics();
