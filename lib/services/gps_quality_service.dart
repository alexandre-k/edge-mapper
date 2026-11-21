import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../models/hike_trail.dart';

enum GpsQualityLevel {
  good,
  fair,
  poor,
  suspect,
  unavailable;

  bool get shouldAdvertiseWarning =>
      this == GpsQualityLevel.poor ||
      this == GpsQualityLevel.suspect ||
      this == GpsQualityLevel.unavailable;

  String get shortLabel => switch (this) {
        GpsQualityLevel.good => 'GPS Accurate',
        GpsQualityLevel.fair => 'GPS OK',
        GpsQualityLevel.poor => 'Weak GPS',
        GpsQualityLevel.suspect => 'Suspect GPS!',
        GpsQualityLevel.unavailable => 'No GPS Fix',
      };
}

class GpsQualityReport {
  final GpsQualityLevel level;
  final String headline;
  final String detail;
  final double? accuracyMeters;
  final double? jumpMeters;
  final bool isMocked;

  const GpsQualityReport({
    required this.level,
    required this.headline,
    required this.detail,
    this.accuracyMeters,
    this.jumpMeters,
    this.isMocked = false,
  });

  static const unavailable = GpsQualityReport(
    level: GpsQualityLevel.unavailable,
    headline: 'GPS Location Unavailable',
    detail: 'Waiting for satellite fix. Step outdoors for a clear sky view.',
  );
}

/// Evaluates incoming GPS fixes to detect and advertise inaccurate, stale,
/// mocked, Null-Island (0,0), or impossible-teleport locations.
class GpsQualityService {
  Position? _lastReliableFix;

  void reset() {
    _lastReliableFix = null;
  }

  GpsQualityReport evaluate(
    Position? position, {
    DateTime? now,
    String? locationError,
  }) {
    if (position == null) {
      return GpsQualityReport(
        level: GpsQualityLevel.unavailable,
        headline: 'GPS Not Locked',
        detail: locationError ??
            'No GPS fix yet — location on the map may be missing or wrong.',
      );
    }

    return evaluateRaw(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMeters: position.accuracy,
      timestamp: position.timestamp,
      isMocked: position.isMocked,
      now: now,
      recordAsLastReliable: true,
      previousLat: _lastReliableFix?.latitude,
      previousLon: _lastReliableFix?.longitude,
      previousTimestamp: _lastReliableFix?.timestamp,
      onReliable: () => _lastReliableFix = position,
    );
  }

  /// Pure-Dart evaluator for easy unit testing and direct use.
  static GpsQualityReport evaluateRaw({
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required DateTime timestamp,
    bool isMocked = false,
    DateTime? now,
    double? previousLat,
    double? previousLon,
    DateTime? previousTimestamp,
    bool recordAsLastReliable = false,
    void Function()? onReliable,
  }) {
    final clock = now ?? DateTime.now();

    // 1. Invalid coordinates or Null Island (0, 0)
    if (latitude.isNaN ||
        longitude.isNaN ||
        latitude.abs() > 90 ||
        longitude.abs() > 180 ||
        (latitude.abs() < 0.0001 && longitude.abs() < 0.0001)) {
      return const GpsQualityReport(
        level: GpsQualityLevel.suspect,
        headline: 'Suspected Invalid GPS (0, 0)',
        detail:
            'Your GPS is reporting Null Island (0°, 0°). Wait for a real satellite lock before mapping.',
      );
    }

    // 2. Mocked / spoofed GPS provider
    if (isMocked) {
      return GpsQualityReport(
        level: GpsQualityLevel.suspect,
        headline: 'Simulated / Mocked GPS Detected',
        detail:
            'A mock location app is providing coordinates. Disable mock locations for real field mapping.',
        accuracyMeters: accuracyMeters,
        isMocked: true,
      );
    }

    // 3. Impossible teleport / sudden jump check
    if (previousLat != null &&
        previousLon != null &&
        previousTimestamp != null) {
      final jumpMeters = haversineMeters(
        previousLat,
        previousLon,
        latitude,
        longitude,
      );
      final dtSeconds = math.max(
        timestamp.difference(previousTimestamp).inMilliseconds.abs() / 1000.0,
        0.5,
      );
      final speedMps = jumpMeters / dtSeconds;
      if (jumpMeters > 120.0 && (speedMps > 45.0 || dtSeconds <= 3.0)) {
        return GpsQualityReport(
          level: GpsQualityLevel.suspect,
          headline: 'Suspected GPS Jump Detected!',
          detail:
              'Location jumped +${jumpMeters.toStringAsFixed(0)}m in ${dtSeconds.toStringAsFixed(1)}s. '
              'Check the map — GPS may have drifted indoors or near tall buildings.',
          accuracyMeters: accuracyMeters,
          jumpMeters: jumpMeters,
        );
      }
    }

    // 4. Stale GPS reading
    final ageSeconds = clock.difference(timestamp).inSeconds;
    if (ageSeconds > 45) {
      return GpsQualityReport(
        level: GpsQualityLevel.poor,
        headline: 'Stale GPS Location (${ageSeconds}s old)',
        detail:
            'Coordinates have not updated recently. Tap refresh or move to open sky.',
        accuracyMeters: accuracyMeters,
      );
    }

    // 5. Critically poor accuracy
    if (accuracyMeters > 65.0) {
      return GpsQualityReport(
        level: GpsQualityLevel.suspect,
        headline: 'Very Low GPS Accuracy (±${accuracyMeters.toStringAsFixed(0)}m)',
        detail:
            'Location is likely inaccurate (indoors, urban canyon, or heavy canopy). Verify position on the map!',
        accuracyMeters: accuracyMeters,
      );
    }

    // 6. Moderate poor accuracy
    if (accuracyMeters > 30.0) {
      if (recordAsLastReliable) onReliable?.call();
      return GpsQualityReport(
        level: GpsQualityLevel.poor,
        headline: 'Weak GPS Signal (±${accuracyMeters.toStringAsFixed(0)}m)',
        detail:
            'Position may be offset by ~${accuracyMeters.toStringAsFixed(0)}m. Give GPS a few seconds to settle.',
        accuracyMeters: accuracyMeters,
      );
    }

    if (recordAsLastReliable) onReliable?.call();

    if (accuracyMeters <= 12.0) {
      return GpsQualityReport(
        level: GpsQualityLevel.good,
        headline: 'GPS Locked (±${accuracyMeters.toStringAsFixed(0)}m)',
        detail: 'High-precision satellite fix.',
        accuracyMeters: accuracyMeters,
      );
    }

    return GpsQualityReport(
      level: GpsQualityLevel.fair,
      headline: 'GPS Fair (±${accuracyMeters.toStringAsFixed(0)}m)',
      detail: 'Good enough for field mapping.',
      accuracyMeters: accuracyMeters,
    );
  }
}
