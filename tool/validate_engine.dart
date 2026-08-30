// Standalone engine validation — runs with plain `dart run`, no test
// framework, so it works even where the local flutter test runner is
// broken. Mirrors the assertions in test/restriction_engine_test.dart
// (which CI runs through `flutter test`).
import 'package:ulimit/core/engine/restriction_engine.dart';

int passed = 0;
int failed = 0;

void check(String label, Object? actual, Object? expected) {
  final ok = '$actual' == '$expected';
  if (ok) {
    passed++;
  } else {
    failed++;
    print('FAIL: $label\n  expected: $expected\n  actual:   $actual');
  }
}

void main() {
  final noon = DateTime(2026, 8, 25, 12, 0);

  EngineInput base({
    DateTime? now,
    List<ManualRule> manual = const [],
    Map<String, int> usage = const {},
    Map<String, int> limits = const {},
    List<GroupRule> groups = const [],
    FocusState? focus,
    BedtimeState? bedtime,
    Set<String> internet = const {},
  }) =>
      EngineInput(
        now: now ?? noon,
        manualRules: manual,
        usageTodaySeconds: usage,
        appLimits: limits,
        groups: groups,
        focus: focus,
        bedtime: bedtime,
        internetBlocks: internet,
      );

  // no policy → allowed
  var d = resolvePackage(base(), 'com.example.app');
  check('allow', d.appBlocked, false);

  // temporary manual block
  d = resolvePackage(
    base(
      manual: [
        ManualRule(
          packageName: 'com.instagram.android',
          permanent: false,
          expiresAt: noon.add(const Duration(hours: 2)),
        ),
      ],
    ),
    'com.instagram.android',
  );
  check('manual blocks', d.appBlocked, true);
  check('manual reason', d.reason, BlockReason.manual);
  check('manual until', d.until, noon.add(const Duration(hours: 2)));

  // expired
  d = resolvePackage(
    base(
      manual: [
        ManualRule(
          packageName: 'com.instagram.android',
          permanent: false,
          expiresAt: noon.subtract(const Duration(seconds: 1)),
        ),
      ],
    ),
    'com.instagram.android',
  );
  check('expired allows', d.appBlocked, false);

  // permanent
  d = resolvePackage(
    base(manual: [ManualRule(packageName: 'com.ig', permanent: true)]),
    'com.ig',
  );
  check('permanent blocks', d.appBlocked, true);
  check('permanent until null', d.until, null);

  // daily limit → end of day
  d = resolvePackage(base(usage: {'com.yt': 1800}, limits: {'com.yt': 1800}), 'com.yt');
  check('limit blocks', d.appBlocked, true);
  check('limit reason', d.reason, BlockReason.dailyLimit);
  check('limit until EOD', d.until, DateTime(2026, 8, 26));

  // group limit
  final group = GroupRule(limitSeconds: 3600, packages: ['com.ig', 'com.rd', 'com.fb']);
  final groupInput = base(
    usage: {'com.ig': 2400, 'com.rd': 1200, 'com.fb': 600},
    groups: [group],
  );
  check('group member blocked', resolvePackage(groupInput, 'com.ig').appBlocked, true);
  check('group member2 blocked', resolvePackage(groupInput, 'com.fb').appBlocked, true);
  check('non-member allowed', resolvePackage(groupInput, 'com.other').appBlocked, false);

  // focus
  d = resolvePackage(
    base(
      focus: FocusState(
        blockedPackages: ['com.ig'],
        endsAt: noon.add(const Duration(minutes: 25)),
      ),
    ),
    'com.ig',
  );
  check('focus blocks', d.appBlocked, true);
  check('focus reason', d.reason, BlockReason.focus);

  // bedtime overnight 23:00 → 06:30
  final bedtime = BedtimeState(
    startMinutes: 23 * 60,
    endMinutes: 6 * 60 + 30,
    selectedApps: ['com.ig'],
  );
  d = resolvePackage(
    base(now: DateTime(2026, 8, 25, 23, 30), bedtime: bedtime),
    'com.ig',
  );
  check('bedtime blocks', d.appBlocked, true);
  check('bedtime until', d.until, DateTime(2026, 8, 26, 6, 30));
  d = resolvePackage(
    base(now: DateTime(2026, 8, 26, 1, 0), bedtime: bedtime),
    'com.ig',
  );
  check('bedtime after-midnight until', d.until, DateTime(2026, 8, 26, 6, 30));
  d = resolvePackage(
    base(now: DateTime(2026, 8, 25, 14, 0), bedtime: bedtime),
    'com.ig',
  );
  check('bedtime day allows', d.appBlocked, false);

  // most-restrictive-wins with earliest expiry reported
  d = resolvePackage(
    base(
      manual: [
        ManualRule(
          packageName: 'com.ig',
          permanent: false,
          expiresAt: noon.add(const Duration(hours: 2)),
        ),
      ],
      focus: FocusState(
        blockedPackages: ['com.ig'],
        endsAt: noon.add(const Duration(minutes: 30)),
      ),
    ),
    'com.ig',
  );
  check('earliest reason', d.reason, BlockReason.focus);
  check('earliest until', d.until, noon.add(const Duration(minutes: 30)));

  // app block implies internet block
  d = resolvePackage(
    base(manual: [ManualRule(packageName: 'com.ig', permanent: true)]),
    'com.ig',
  );
  check('app block implies net block', d.internetBlocked, true);

  // explicit internet block on allowed app
  d = resolvePackage(base(internet: {'com.wa'}), 'com.wa');
  check('net-only allowed app', d.appBlocked, false);
  check('net-only net blocked', d.internetBlocked, true);

  // window math
  check('window same-day', isMinuteInWindow(10 * 60, 9 * 60, 17 * 60), true);
  check('window overnight pm', isMinuteInWindow(23 * 60 + 30, 23 * 60, 6 * 60 + 30), true);
  check('window overnight am', isMinuteInWindow(2 * 60, 23 * 60, 6 * 60 + 30), true);
  check('window overnight day', isMinuteInWindow(12 * 60, 23 * 60, 6 * 60 + 30), false);
  check('window zero-length', isMinuteInWindow(0, 0, 0), false);

  // formatting
  check('clock 24:18', formatClock(const Duration(minutes: 24, seconds: 18)), '24:18');
  check('clock 1:04:09', formatClock(const Duration(hours: 1, minutes: 4, seconds: 9)), '1:04:09');
  check('clock negative', formatClock(const Duration(seconds: -5)), '00:00');
  check('short 4h18m', formatDurationShort(const Duration(hours: 4, minutes: 18)), '4h 18m');
  check('short 36m', formatDurationShort(const Duration(minutes: 36)), '36m');
  check('short 2h', formatDurationShort(const Duration(hours: 2)), '2h');

  // activeManualRules
  final active = activeManualRules(
    [
      ManualRule(packageName: 'a', permanent: true),
      ManualRule(
        packageName: 'b',
        permanent: false,
        expiresAt: noon.add(const Duration(minutes: 1)),
      ),
      ManualRule(
        packageName: 'c',
        permanent: false,
        expiresAt: noon.subtract(const Duration(minutes: 1)),
      ),
    ],
    noon,
  );
  check('active rules', active.map((r) => r.packageName).join(','), 'a,b');

  print('\n$passed passed, $failed failed');
  if (failed > 0) {
    throw StateError('engine validation failed');
  }
}
