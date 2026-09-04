import 'package:flutter_test/flutter_test.dart';
import 'package:ulimit/core/engine/restriction_engine.dart';

void main() {
  final tuesdayNoon = DateTime(2026, 8, 25, 12, 0);

  EngineInput base({
    DateTime? now,
    List<ManualRule> manual = const [],
    Map<String, int> usage = const {},
    Map<String, int> limits = const {},
    List<GroupRule> groups = const [],
    FocusState? focus,
    BedtimeState? bedtime,
    Set<String> internet = const {},
    DoomscrollState? doomscroll,
    Map<String, int> doomOpens = const {},
  }) {
    return EngineInput(
      now: now ?? tuesdayNoon,
      manualRules: manual,
      usageTodaySeconds: usage,
      appLimits: limits,
      groups: groups,
      focus: focus,
      bedtime: bedtime,
      internetBlocks: internet,
      doomscroll: doomscroll,
      doomscrollOpensToday: doomOpens,
    );
  }

  group('resolvePackage', () {
    test('allows a package with no active policy', () {
      final d = resolvePackage(base(), 'com.example.app');
      expect(d.appBlocked, isFalse);
      expect(d.internetBlocked, isFalse);
    });

    test('temporary manual restriction blocks until expiry', () {
      final d = resolvePackage(
        base(
          manual: [
            ManualRule(
              packageName: 'com.instagram.android',
              permanent: false,
              expiresAt: tuesdayNoon.add(const Duration(hours: 2)),
            ),
          ],
        ),
        'com.instagram.android',
      );
      expect(d.appBlocked, isTrue);
      expect(d.reason, BlockReason.manual);
      expect(d.until, tuesdayNoon.add(const Duration(hours: 2)));
    });

    test('expired manual restriction no longer blocks', () {
      final d = resolvePackage(
        base(
          manual: [
            ManualRule(
              packageName: 'com.instagram.android',
              permanent: false,
              expiresAt: tuesdayNoon.subtract(const Duration(seconds: 1)),
            ),
          ],
        ),
        'com.instagram.android',
      );
      expect(d.appBlocked, isFalse);
    });

    test('permanent restriction blocks indefinitely (until == null)', () {
      final d = resolvePackage(
        base(
          manual: [ManualRule(packageName: 'com.instagram.android', permanent: true)],
        ),
        'com.instagram.android',
      );
      expect(d.appBlocked, isTrue);
      expect(d.until, isNull);
    });

    test('daily limit blocks until end of day when usage reaches limit', () {
      final d = resolvePackage(
        base(usage: {'com.yt': 1800}, limits: {'com.yt': 1800}),
        'com.yt',
      );
      expect(d.appBlocked, isTrue);
      expect(d.reason, BlockReason.dailyLimit);
      expect(d.until, DateTime(2026, 8, 26)); // next midnight
    });

    test('daily limit resets on a new day (usage is per-day input)', () {
      // Fresh day: usage map empty → allowed even with a limit set.
      final d = resolvePackage(base(limits: {'com.yt': 1800}), 'com.yt');
      expect(d.appBlocked, isFalse);
    });

    test('group limit blocks every member once the shared pool is spent', () {
      final group = GroupRule(
        limitSeconds: 3600,
        packages: ['com.ig', 'com.rd', 'com.fb'],
      );
      final input = base(
        usage: {'com.ig': 2400, 'com.rd': 1200, 'com.fb': 600},
        groups: [group],
      );
      for (final pkg in ['com.ig', 'com.rd', 'com.fb']) {
        final d = resolvePackage(input, pkg);
        expect(d.appBlocked, isTrue, reason: pkg);
        expect(d.reason, BlockReason.groupLimit);
      }
      // Non-member unaffected.
      expect(resolvePackage(input, 'com.other').appBlocked, isFalse);
    });

    test('group under limit does not block', () {
      final group = GroupRule(limitSeconds: 3600, packages: ['com.ig', 'com.rd']);
      final d = resolvePackage(
        base(usage: {'com.ig': 600, 'com.rd': 600}, groups: [group]),
        'com.ig',
      );
      expect(d.appBlocked, isFalse);
    });

    test('feed-native doomscroll budget of 0 blocks the app outright', () {
      final d = resolvePackage(
        base(
          doomscroll: DoomscrollState(openLimits: {'com.reddit.frontpage': 0}),
          doomOpens: {'com.reddit.frontpage': 0},
        ),
        'com.reddit.frontpage',
      );
      expect(d.appBlocked, isTrue);
      expect(d.reason, BlockReason.doomscroll);
      // Outright block is indefinite — it ends when the rule is removed.
      expect(d.until, isNull);
    });

    test('feed-native doomscroll budget of 0 blocks even with zero opens', () {
      final d = resolvePackage(
        base(doomscroll: DoomscrollState(openLimits: {'com.reddit.frontpage': 0})),
        'com.reddit.frontpage',
      );
      expect(d.appBlocked, isTrue);
      expect(d.reason, BlockReason.doomscroll);
    });

    test('feed-native doomscroll blocks after the opens budget is spent', () {
      final d = resolvePackage(
        base(
          doomscroll: DoomscrollState(openLimits: {'com.reddit.frontpage': 5}),
          doomOpens: {'com.reddit.frontpage': 5},
        ),
        'com.reddit.frontpage',
      );
      expect(d.appBlocked, isTrue);
      expect(d.reason, BlockReason.doomscroll);
    });

    test('feed-native doomscroll under budget stays allowed', () {
      final d = resolvePackage(
        base(
          doomscroll: DoomscrollState(openLimits: {'com.reddit.frontpage': 5}),
          doomOpens: {'com.reddit.frontpage': 4},
        ),
        'com.reddit.frontpage',
      );
      expect(d.appBlocked, isFalse);
    });

    test('doomscroll rules do not touch unmanaged packages', () {
      final d = resolvePackage(
        base(
          doomscroll: DoomscrollState(openLimits: {'com.reddit.frontpage': 0}),
          doomOpens: {'com.other': 99},
        ),
        'com.other',
      );
      expect(d.appBlocked, isFalse);
    });

    test('doomscroll block implies internet block (no web-version loophole)', () {
      final d = resolvePackage(
        base(doomscroll: DoomscrollState(openLimits: {'com.reddit.frontpage': 0})),
        'com.reddit.frontpage',
      );
      expect(d.internetBlocked, isTrue);
    });

    test('focus blocks listed packages until session end', () {
      final d = resolvePackage(
        base(
          focus: FocusState(
            blockedPackages: ['com.ig', 'com.rd'],
            endsAt: tuesdayNoon.add(const Duration(minutes: 25)),
          ),
        ),
        'com.ig',
      );
      expect(d.appBlocked, isTrue);
      expect(d.reason, BlockReason.focus);
      expect(d.until, tuesdayNoon.add(const Duration(minutes: 25)));
      // Unlisted package unaffected.
      expect(resolvePackage(base(), 'com.other').appBlocked, isFalse);
    });

    test('bedtime blocks selected apps during an overnight window', () {
      // Window 23:00 → 06:30; now = 2026-08-25 23:30.
      final now = DateTime(2026, 8, 25, 23, 30);
      final bedtime = BedtimeState(
        startMinutes: 23 * 60,
        endMinutes: 6 * 60 + 30,
        selectedApps: ['com.ig'],
      );
      final d = resolvePackage(base(now: now, bedtime: bedtime), 'com.ig');
      expect(d.appBlocked, isTrue);
      expect(d.reason, BlockReason.bedtime);
      // Ends tomorrow morning at 06:30.
      expect(d.until, DateTime(2026, 8, 26, 6, 30));
    });

    test('bedtime after midnight resolves to the same morning end', () {
      final now = DateTime(2026, 8, 26, 1, 0);
      final bedtime = BedtimeState(
        startMinutes: 23 * 60,
        endMinutes: 6 * 60 + 30,
        selectedApps: ['com.ig'],
      );
      final d = resolvePackage(base(now: now, bedtime: bedtime), 'com.ig');
      expect(d.appBlocked, isTrue);
      expect(d.until, DateTime(2026, 8, 26, 6, 30));
    });

    test('bedtime outside the window does not block', () {
      final now = DateTime(2026, 8, 25, 14, 0);
      final bedtime = BedtimeState(
        startMinutes: 23 * 60,
        endMinutes: 6 * 60 + 30,
        selectedApps: ['com.ig'],
      );
      expect(resolvePackage(base(now: now, bedtime: bedtime), 'com.ig').appBlocked, isFalse);
    });

    test('most restrictive wins and earliest expiry is reported', () {
      // Focus (ends 12:30) + manual (ends 14:00) → blocked, reason focus.
      final d = resolvePackage(
        base(
          manual: [
            ManualRule(
              packageName: 'com.ig',
              permanent: false,
              expiresAt: tuesdayNoon.add(const Duration(hours: 2)),
            ),
          ],
          focus: FocusState(
            blockedPackages: ['com.ig'],
            endsAt: tuesdayNoon.add(const Duration(minutes: 30)),
          ),
        ),
        'com.ig',
      );
      expect(d.appBlocked, isTrue);
      expect(d.reason, BlockReason.focus);
      expect(d.until, tuesdayNoon.add(const Duration(minutes: 30)));
    });

    test('app block implies internet block (no web-version loophole)', () {
      final d = resolvePackage(
        base(
          manual: [ManualRule(packageName: 'com.ig', permanent: true)],
        ),
        'com.ig',
      );
      expect(d.internetBlocked, isTrue);
    });

    test('explicit internet block works on an otherwise-allowed app', () {
      final d = resolvePackage(base(internet: {'com.wa'}), 'com.wa');
      expect(d.appBlocked, isFalse);
      expect(d.internetBlocked, isTrue);
    });
  });

  group('isMinuteInWindow / windowEndFor', () {
    test('same-day window', () {
      expect(isMinuteInWindow(10 * 60, 9 * 60, 17 * 60), isTrue);
      expect(isMinuteInWindow(18 * 60, 9 * 60, 17 * 60), isFalse);
    });

    test('overnight window both halves', () {
      expect(isMinuteInWindow(23 * 60 + 30, 23 * 60, 6 * 60 + 30), isTrue);
      expect(isMinuteInWindow(2 * 60, 23 * 60, 6 * 60 + 30), isTrue);
      expect(isMinuteInWindow(12 * 60, 23 * 60, 6 * 60 + 30), isFalse);
    });

    test('zero-length window never active', () {
      expect(isMinuteInWindow(0, 0, 0), isFalse);
    });
  });

  group('formatting', () {
    test('clock format', () {
      expect(formatClock(const Duration(minutes: 24, seconds: 18)), '24:18');
      expect(formatClock(const Duration(hours: 1, minutes: 4, seconds: 9)), '1:04:09');
      expect(formatClock(const Duration(seconds: -5)), '00:00');
    });

    test('short duration format', () {
      expect(formatDurationShort(const Duration(hours: 4, minutes: 18)), '4h 18m');
      expect(formatDurationShort(const Duration(minutes: 36)), '36m');
      expect(formatDurationShort(const Duration(hours: 2)), '2h');
      expect(formatDurationShort(Duration.zero), '0m');
    });
  });

  group('activeManualRules', () {
    test('filters expired, keeps permanent', () {
      final rules = [
        ManualRule(packageName: 'a', permanent: true),
        ManualRule(
          packageName: 'b',
          permanent: false,
          expiresAt: tuesdayNoon.add(const Duration(minutes: 1)),
        ),
        ManualRule(
          packageName: 'c',
          permanent: false,
          expiresAt: tuesdayNoon.subtract(const Duration(minutes: 1)),
        ),
      ];
      final active = activeManualRules(rules, tuesdayNoon);
      expect(active.map((r) => r.packageName), ['a', 'b']);
    });
  });
}
