import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'gps_quality_service.dart';

class CompassReading {
  final double? headingDegrees;
  final int accuracy;

  const CompassReading({
    required this.headingDegrees,
    required this.accuracy,
  });
}

/// Manages GPS location fixes, continuous background-safe route GPS streams
/// (using Android Foreground Service + WakeLock so recording continues even
/// when minimized or screen-off), real-time GPS quality/anomaly detection,
/// and the native Android compass EventChannel (`com.edgemapper.app/compass`).
class SensorService extends ChangeNotifier {
  static const EventChannel _compassChannel =
      EventChannel('com.edgemapper.app/compass');
  static const MethodChannel _trailBgChannel =
      MethodChannel('com.edgemapper.app/trail_background');

  final GpsQualityService _gpsQualityService = GpsQualityService();
  final StreamController<Position> _trailTrackController =
      StreamController<Position>.broadcast();

  StreamSubscription<dynamic>? _compassSub;
  StreamSubscription<Position>? _positionSub;

  Position? _currentPosition;
  GpsQualityReport _gpsQuality = GpsQualityReport.unavailable;
  double? _headingDegrees;
  int _compassAccuracy = 0;
  String? _locationError;
  bool _hasLocationPermission = false;
  bool _isTrailRecordingActive = false;

  Position? get currentPosition => _currentPosition;
  GpsQualityReport get gpsQuality => _gpsQuality;
  double? get headingDegrees => _headingDegrees;
  int get compassAccuracy => _compassAccuracy;
  String? get locationError => _locationError;
  bool get hasLocationPermission => _hasLocationPermission;
  bool get isBackgroundTrailTracking => _isTrailRecordingActive;

  Future<void> init() async {
    _startCompassStream();
    await ensureLocationPermissionAndFix();
  }

  void _updatePosition(Position? pos) {
    _currentPosition = pos;
    _gpsQuality = _gpsQualityService.evaluate(
      pos,
      locationError: _locationError,
    );
    notifyListeners();
  }

  void _startCompassStream() {
    if (kIsWeb) return;
    _compassSub?.cancel();
    _compassSub = _compassChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final rawHeading = event['heading'];
          final rawAccuracy = event['accuracy'];
          _headingDegrees = rawHeading is num ? rawHeading.toDouble() : null;
          _compassAccuracy = rawAccuracy is int ? rawAccuracy : 0;
          notifyListeners();
        }
      },
      onError: (Object error) {
        debugPrint('[EdgeMapper] Compass stream error: $error');
      },
    );
  }

  Future<bool> ensureLocationPermissionAndFix() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _locationError = 'Location services (GPS) are disabled on device.';
        _hasLocationPermission = false;
        _updatePosition(_currentPosition);
        return false;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _locationError = kIsWeb
            ? 'Allow location in browser.'
            : 'Enable GPS permission in Settings.';
        _hasLocationPermission = false;
        _updatePosition(_currentPosition);
        return false;
      }

      _hasLocationPermission = true;
      _locationError = null;
      notifyListeners();

      await refreshCurrentPosition();
      if (!_isTrailRecordingActive) {
        _startPassivePositionUpdates();
      }
      return true;
    } catch (e) {
      _locationError = 'GPS error: $e';
      _updatePosition(_currentPosition);
      return false;
    }
  }

  Future<Position?> refreshCurrentPosition() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      _locationError = null;
      _updatePosition(pos);
      return pos;
    } catch (e) {
      try {
        final lastKnown = await Geolocator.getLastKnownPosition();
        if (lastKnown != null) {
          _updatePosition(lastKnown);
          return lastKnown;
        }
      } catch (_) {}
      _locationError = 'Waiting for GPS fix... ($e)';
      _updatePosition(_currentPosition);
      return _currentPosition;
    }
  }

  /// Builds platform-appropriate location settings for active trail recording.
  /// On Android, attaches an ongoing Foreground Service notification with
  /// WakeLock enabled so GPS points keep recording reliably even when the app
  /// is minimized or the screen is locked.
  static LocationSettings buildTrailLocationSettings({
    int distanceFilterMeters = 5,
    String? trailName,
    bool? forceAndroidForTest,
  }) {
    final isAndroid = forceAndroidForTest ??
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
    if (isAndroid) {
      final cleanName = trailName?.trim() ?? '';
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: distanceFilterMeters,
        intervalDuration: const Duration(seconds: 3),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'Recording Route',
          notificationText: cleanName.isNotEmpty
              ? '$cleanName · Tracking GPS in background'
              : 'Edge Mapper is tracking your GPS trail in the background',
          notificationChannelName: 'Active Route Recording',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    return LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: distanceFilterMeters,
    );
  }

  void _startPassivePositionUpdates() {
    if (_isTrailRecordingActive) return;
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 4,
      ),
    ).listen(
      (position) {
        _locationError = null;
        _updatePosition(position);
      },
      onError: (Object error) {
        debugPrint('[EdgeMapper] GPS stream error: $error');
      },
    );
  }

  Future<void> _ensureAndroidNotificationPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _trailBgChannel.invokeMethod<bool>('ensureNotificationPermission');
    } catch (_) {}
  }

  /// Promotes the single managed GPS position stream to a high-accuracy
  /// background-safe Android Foreground Service stream (with WakeLock and
  /// ongoing notification) so trail recording keeps working when minimized.
  Stream<Position> startHikeTrackStream({
    int distanceFilterMeters = 5,
    String? trailName,
  }) {
    _isTrailRecordingActive = true;
    notifyListeners();

    // ignore: unawaited_futures
    _startForegroundTrailStream(
      distanceFilterMeters: distanceFilterMeters,
      trailName: trailName,
    );

    return _trailTrackController.stream;
  }

  Future<void> _startForegroundTrailStream({
    required int distanceFilterMeters,
    String? trailName,
  }) async {
    await _ensureAndroidNotificationPermission();
    // Cancel any existing passive GPS stream first so GeolocatorLocationService
    // transitions cleanly into foreground-service mode without dual listeners.
    await _positionSub?.cancel();
    _positionSub = null;
    if (!_isTrailRecordingActive) return;

    final settings = buildTrailLocationSettings(
      distanceFilterMeters: distanceFilterMeters,
      trailName: trailName,
    );
    _positionSub = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      (position) {
        _locationError = null;
        _updatePosition(position);
        if (_isTrailRecordingActive && !_trailTrackController.isClosed) {
          _trailTrackController.add(position);
        }
      },
      onError: (Object error) {
        debugPrint('[EdgeMapper] Background trail GPS stream error: $error');
      },
    );
  }

  /// Stops the foreground-service trail GPS stream (removing the persistent
  /// Android notification and releasing WakeLock) and resumes passive GPS.
  Future<void> stopHikeTrackStream() async {
    if (!_isTrailRecordingActive) return;
    _isTrailRecordingActive = false;
    await _positionSub?.cancel();
    _positionSub = null;
    notifyListeners();

    if (_hasLocationPermission) {
      _startPassivePositionUpdates();
    }
  }

  @override
  void dispose() {
    _isTrailRecordingActive = false;
    _compassSub?.cancel();
    _positionSub?.cancel();
    _trailTrackController.close();
    super.dispose();
  }
}
