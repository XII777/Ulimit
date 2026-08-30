import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The app's single icon system: the Solar Bold set, shipped as tinted
/// monochrome SVG assets. Every icon the app uses is listed here once —
/// screens reference [AppIconName] values, never raw asset paths, so a
/// rename is a one-line change and an audit of "which icons exist" is
/// just this enum.
///
/// All icons render at 24x24 design size and are recolored with a
/// `srcIn` color filter, which respects the design system's rule that
/// iconography never introduces a second hue.
enum AppIconName {
  home('home-angle-2'),
  focus('target'),
  limits('slider-minimalistic-horizontal'),
  bedtime('moon-sleep'),
  settings('settings-minimalistic'),
  stopwatch('stopwatch'),
  widget('widget'),
  block('slash-circle'),
  internet('global'),
  notifications('bell-bing'),
  notificationsOff('bell-off'),
  shield('shield'),
  shieldLock('shield-keyhole'),
  play('play-circle'),
  pause('pause-circle'),
  check('check-circle'),
  close('close-circle'),
  back('alt-arrow-left'),
  chevronRight('alt-arrow-right'),
  chevronDown('alt-arrow-down'),
  add('add-circle'),
  search('magnifer'),
  trash('trash-bin-trash'),
  edit('pen'),
  refresh('refresh'),
  power('power'),
  filter('filter'),
  link('link-circle'),
  lock('lock-keyhole'),
  biometric('eye-scan'),
  visibility('eye'),
  warning('danger-triangle'),
  info('info-circle'),
  hourglass('hourglass'),
  clock('clock-circle'),
  bed('bed'),
  moon('moon'),
  phone('smartphone'),
  chart('chart'),
  export('export'),
  import('import'),
  star('star'),
  haptics('smartphone-vibration'),
  trend('graph-up'),
  userBlock('user-block');

  const AppIconName(this.asset);
  final String asset;
}

class AppIcon extends StatelessWidget {
  const AppIcon(
    this.name, {
    super.key,
    this.size = 18,
    this.color,
  });

  final AppIconName name;
  final double size;
  final Color? color;

  static const _assetDir = 'assets/icons';

  @override
  Widget build(BuildContext context) {
    final effective = color ?? Theme.of(context).iconTheme.color ?? AppColors.ink;
    // NOTE: these SVGs are the app's OWN assets — no `package:` prefix.
    // Package-prefixed asset keys only resolve for dependency packages;
    // for the root app they 404 and flutter_svg fails every screen.
    return SvgPicture.asset(
      '$_assetDir/${name.asset}.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(effective, BlendMode.srcIn),
      // An icon must never take down a screen — render empty instead.
      errorBuilder: (_, __, ___) => SizedBox(width: size, height: size),
    );
  }
}
