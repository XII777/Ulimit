import 'package:flutter_test/flutter_test.dart';
import 'package:ulimit/data/providers.dart';

void main() {
  group('bucketByDay (timezone regression)', () {
    // The window always starts 6 days before "today": index 0 = 6 days
    // ago … index 6 = today. Rows arrive as Drift returns them — UTC
    // DateTimes for the instant of the stored local midnight.
    final start = DateTime(2026, 8, 25); // 6 days before Aug 31
    final today = DateTime(2026, 8, 31);

    test('buckets UTC-stored day instants into the correct local slots', () {
      // Instant of Aug 31 midnight, expressed in UTC (what Drift
      // returns for the stored unix-seconds value).
      final storedAsUtc = today.toUtc();

      final buckets = bucketByDay([(storedAsUtc, 3600)], start);

      expect(buckets.length, 7);
      expect(buckets[6].inSeconds, 3600); // today's slot
      expect(
          buckets
              .asMap()
              .entries
              .where((e) => e.key != 6)
              .fold(0, (a, e) => a + e.value.inSeconds),
          0);
    });

    test('aggregates multiple rows on the same local day', () {
      final yesterday = DateTime(2026, 8, 30);

      final buckets = bucketByDay(
          [(yesterday.toUtc(), 1200), (yesterday.add(const Duration(hours: 5)).toUtc(), 600)],
          start);

      expect(buckets[5].inSeconds, 1800); // yesterday's slot
    });

    test('values outside the 7-day window do not leak into buckets', () {
      final outside = DateTime(2026, 8, 20); // before window start

      final buckets = bucketByDay([(outside.toUtc(), 9999), (today.toUtc(), 60)], start);

      expect(buckets.length, greaterThanOrEqualTo(7));
      // The outside-day row must NOT steal today's bucket; today holds.
      final todayIdx = buckets.length - 1;
      expect(buckets[todayIdx].inSeconds, 60);
    });
  });
}
