import 'package:flutter/material.dart';

/// The app's one scroll feel: iOS-style bouncing with a spring settle,
/// applied to every scrolling surface. Android's default clamping
/// physics reads as "system app"; the brief, physical bounce is part
/// of the design language (motion communicates state, here "you've
/// reached the end").
const ScrollPhysics springScrollPhysics = BouncingScrollPhysics(
  parent: RangeMaintainingScrollPhysics(),
  decelerationRate: ScrollDecelerationRate.fast,
);
