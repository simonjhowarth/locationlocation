/// Simple 1D Kalman filter for smoothing scalar measurements.
class OneDKalman {
  double q; // process noise
  double r; // measurement noise
  double? x; // estimated value
  double p; // estimation error covariance
  bool initialized = false;

  OneDKalman({this.q = 1e-5, this.r = 1e-2}) : p = 1.0;

  double filter(double measurement) {
    if (!initialized) {
      x = measurement;
      initialized = true;
      return x!;
    }
    p = p + q;
    final k = p / (p + r);
    x = x! + k * (measurement - x!);
    p = (1 - k) * p;
    return x!;
  }

  void reset() {
    initialized = false;
    p = 1.0;
    x = null;
  }
}
