import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/screens/accounts.dart';

void main() {
  test('resetText counts down live from resetsAt and appends the clock', () {
    final at = DateTime.now().add(const Duration(hours: 4, minutes: 49, seconds: 30)).toUtc().toIso8601String();
    expect(resetText({'pct': 1, 'resetsAt': at, 'countdown': '9h 00m', 'clock': '22:10'}), 'resets in 4h 49m · 22:10');
  });

  test('resetText falls back to the provider countdown without resetsAt', () {
    expect(resetText({'pct': 42, 'countdown': '2h 10m'}), 'resets in 2h 10m');
  });

  test('resetText says the reset is due when resetsAt has passed', () {
    final at = DateTime.now().subtract(const Duration(minutes: 3)).toUtc().toIso8601String();
    expect(resetText({'pct': 100, 'resetsAt': at}), 'reset due now');
  });

  test('resetText is empty when the window has no reset information', () {
    expect(resetText({'pct': 0}), '');
  });
}
