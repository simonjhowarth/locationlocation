import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/filters/kalman.dart';

void main() {
  test('OneDKalman smooths noisy measurements', () {
    final kf = OneDKalman(q: 1e-4, r: 1e-1);
    final trueVal = 10.0;
    final measurements = [10.0, 10.5, 9.7, 10.2, 9.9, 10.3, 9.8, 10.1];
    final filtered = <double>[];
    for (var m in measurements) filtered.add(kf.filter(m));

    double rawDiff = 0.0;
    for (var i = 1; i < measurements.length; i++) {
      rawDiff += (measurements[i] - measurements[i - 1]).abs();
    }
    double filtDiff = 0.0;
    for (var i = 1; i < filtered.length; i++) {
      filtDiff += (filtered[i] - filtered[i - 1]).abs();
    }

    // Filtered path should be smoother (less total variation)
    expect(filtDiff, lessThan(rawDiff));

    // Final filtered value should be reasonably close to the true value
    final lastFiltered = filtered.last;
    final rawLast = measurements.last;
    expect((lastFiltered - trueVal).abs(), lessThan((rawLast - trueVal).abs() * 1.5));
  });
}
