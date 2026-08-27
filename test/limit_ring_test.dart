import 'package:flutter_test/flutter_test.dart';
import 'package:ulimit/shared/widgets/limit_ring.dart';

void main() {
  test('LimitRing clamps progress to 0-1 without throwing', () {
    // Regression guard: a bad DB read or divide-by-zero upstream
    // (e.g. a zero-minute limit) should never crash the ring —
    // it should just render fully empty or full.
    expect(() => LimitRing(progress: 1.4, size: 100), returnsNormally);
    expect(() => LimitRing(progress: -0.2, size: 100), returnsNormally);
  });
}
