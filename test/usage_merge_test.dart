import 'package:flutter_test/flutter_test.dart';
import 'package:ulimit/data/db/app_database.dart';
import 'package:ulimit/data/usage_merge.dart';

void main() {
  group('mergedUsageSeconds — OS wins, tracker fills gaps', () {
    test('OS value wins when present, even if tracker is higher', () {
      // The old bug: tracker attribution stacked on top of an OS value
      // that already contained the same session. OS must simply win.
      expect(mergedUsageSeconds(trackerSeconds: 5000, osSeconds: 3600), 3600);
    });

    test('tracker fills the gap when the OS has nothing yet', () {
      expect(mergedUsageSeconds(trackerSeconds: 42, osSeconds: 0), 42);
    });

    test('both zero stays zero', () {
      expect(mergedUsageSeconds(trackerSeconds: 0, osSeconds: 0), 0);
    });

    test('OS present and tracker zero → OS value', () {
      expect(mergedUsageSeconds(trackerSeconds: 0, osSeconds: 120), 120);
    });

    test('negative tracker values never leak through', () {
      expect(mergedUsageSeconds(trackerSeconds: -5, osSeconds: 0), 0);
      expect(mergedUsageSeconds(trackerSeconds: -5, osSeconds: 30), 30);
    });
  });

  group('AppUsageRowMerge.effectiveSeconds', () {
    final day = DateTime(2026, 9, 4);

    test('applies the same OS-wins rule to a DB row', () {
      final osOnly = AppUsageData(
        id: 1,
        packageName: 'com.instagram.android',
        day: day,
        foregroundSeconds: 5000,
        openCount: 0,
        osForegroundSeconds: 3600,
      );
      expect(osOnly.effectiveSeconds, 3600);

      final trackerOnly = AppUsageData(
        id: 2,
        packageName: 'com.reddit.app',
        day: day,
        foregroundSeconds: 42,
        openCount: 0,
        osForegroundSeconds: 0,
      );
      expect(trackerOnly.effectiveSeconds, 42);
    });
  });
}
