import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/hike_trail.dart';
import 'app_env_config.dart';
import 'offline_tile_service.dart';

class LocationGuess {
  final String suggestedRouteName;
  final ActivityType activityType;
  final String highway;
  final String surface;
  final String countryCode; // e.g. 'jp', 'fr', 'us'
  final String countryLanguage; // ISO 639-1 e.g. 'ja', 'fr', 'en'
  final String locationContext; // Human-readable place summary

  const LocationGuess({
    required this.suggestedRouteName,
    required this.activityType,
    required this.highway,
    required this.surface,
    required this.countryCode,
    required this.countryLanguage,
    required this.locationContext,
  });
}

/// Guesses country language offline from GPS coordinates AND performs online
/// OpenStreetMap Nominatim reverse geocoding to auto-guess walking/park/hiking
/// route names, activity types, and OSM highway/surface defaults.
class LocationContextService {
  static String get userAgent =>
      AppEnvConfig.httpUserAgent(component: 'Nominatim');

  static const int _maxCacheEntries = 96;
  static Duration _minNominatimInterval = const Duration(milliseconds: 1100);
  static DateTime? _lastNominatimRequestAt;
  static DateTime? _nominatimBackoffUntil;
  static Future<void> _nominatimGate = Future<void>.value();
  static final Map<String, String> _overallPlaceCache = {};
  static final Map<String, LocationGuess> _locationGuessCache = {};

  @visibleForTesting
  static void resetNominatimStateForTest({Duration? minInterval}) {
    _minNominatimInterval = minInterval ?? const Duration(milliseconds: 1100);
    _lastNominatimRequestAt = null;
    _nominatimBackoffUntil = null;
    _nominatimGate = Future<void>.value();
    _overallPlaceCache.clear();
    _locationGuessCache.clear();
  }

  static Map<String, String> get _nominatimHeaders => {
        if (!kIsWeb) 'User-Agent': userAgent,
        'Accept': 'application/json',
      };

  /// Serializes outgoing Nominatim calls to strictly honor the OSMF Nominatim
  /// Usage Policy maximum of 1 request/second and HTTP 429/503 backoff.
  static Future<http.Response?> _getNominatim(
    Uri uri, {
    http.Client? client,
  }) async {
    final now = DateTime.now();
    if (_nominatimBackoffUntil != null && _nominatimBackoffUntil!.isAfter(now)) {
      return null;
    }

    final completer = Completer<void>();
    final prev = _nominatimGate;
    _nominatimGate = completer.future;
    try {
      await prev;
      final afterWait = DateTime.now();
      if (_nominatimBackoffUntil != null &&
          _nominatimBackoffUntil!.isAfter(afterWait)) {
        return null;
      }
      if (_lastNominatimRequestAt != null &&
          _minNominatimInterval > Duration.zero) {
        final elapsed = afterWait.difference(_lastNominatimRequestAt!);
        if (elapsed < _minNominatimInterval) {
          await Future<void>.delayed(_minNominatimInterval - elapsed);
        }
      }
      _lastNominatimRequestAt = DateTime.now();
      final req = client != null
          ? client.get(uri, headers: _nominatimHeaders)
          : http.get(uri, headers: _nominatimHeaders);
      final resp = await req.timeout(const Duration(seconds: 7));
      if (resp.statusCode == 429 || resp.statusCode == 503) {
        final backoff = OfflineTileService.parseRetryAfter(
          resp.headers['retry-after'],
          now: DateTime.now(),
          fallback: const Duration(seconds: 60),
        );
        _nominatimBackoffUntil = DateTime.now().add(backoff);
        debugPrint(
          '[EdgeMapper] Nominatim returned HTTP ${resp.statusCode}; '
          'backing off ${backoff.inSeconds}s.',
        );
        return null;
      }
      return resp;
    } finally {
      completer.complete();
    }
  }

  static void _putBounded<T>(Map<String, T> map, String key, T value) {
    if (map.length >= _maxCacheEntries) {
      map.remove(map.keys.first);
    }
    map[key] = value;
  }

  static const Map<String, String> _countryToLanguage = {
    'jp': 'ja',
    'fr': 'fr',
    'de': 'de',
    'at': 'de',
    'ch': 'de',
    'es': 'es',
    'mx': 'es',
    'ar': 'es',
    'co': 'es',
    'pe': 'es',
    'cl': 'es',
    'it': 'it',
    'kr': 'ko',
    'cn': 'zh',
    'tw': 'zh',
    'hk': 'zh',
    'pt': 'pt',
    'br': 'pt',
    'nl': 'nl',
    'be': 'fr',
    'pl': 'pl',
    'ru': 'ru',
    'th': 'th',
    'vn': 'vi',
    'id': 'id',
    'sa': 'ar',
    'ae': 'ar',
    'eg': 'ar',
    'ma': 'ar',
    'gb': 'en',
    'us': 'en',
    'ca': 'en',
    'au': 'en',
    'nz': 'en',
    'ie': 'en',
    'sg': 'en',
  };

  /// Fast offline approximation of the primary country language from GPS lat/lon
  /// so dual-language tagging works even with zero internet connection.
  static String guessCountryLanguageOffline(double lat, double lon) {
    // Japan
    if (lat >= 24.0 && lat <= 46.0 && lon >= 122.0 && lon <= 146.5) return 'ja';
    // South Korea
    if (lat >= 33.0 && lat <= 38.7 && lon >= 124.5 && lon <= 131.0) return 'ko';
    // China / Taiwan
    if (lat >= 18.0 && lat <= 53.5 && lon >= 73.5 && lon <= 135.0) return 'zh';
    // France (metropolitan)
    if (lat >= 41.3 && lat <= 51.1 && lon >= -5.2 && lon <= 9.6) return 'fr';
    // Germany
    if (lat >= 47.2 && lat <= 55.1 && lon >= 5.8 && lon <= 15.1) return 'de';
    // Spain
    if (lat >= 36.0 && lat <= 43.8 && lon >= -9.3 && lon <= 4.3) return 'es';
    // Italy
    if (lat >= 36.6 && lat <= 47.1 && lon >= 6.6 && lon <= 18.6) return 'it';
    // UK & Ireland
    if (lat >= 49.8 && lat <= 60.9 && lon >= -10.5 && lon <= 1.8) return 'en';
    // Thailand
    if (lat >= 5.6 && lat <= 20.5 && lon >= 97.3 && lon <= 105.7) return 'th';
    // Vietnam
    if (lat >= 8.5 && lat <= 23.4 && lon >= 102.1 && lon <= 109.5) return 'vi';
    // Brazil
    if (lat >= -33.8 && lat <= 5.3 && lon >= -74.0 && lon <= -34.7) return 'pt';
    // Default English
    return 'en';
  }

  static String languageForCountryCode(String? countryCode) {
    if (countryCode == null || countryCode.isEmpty) return 'en';
    return _countryToLanguage[countryCode.toLowerCase()] ?? 'en';
  }

  /// Fast offline approximation of the country/region name from GPS coordinates
  /// so the Records overview shows a readable place even with zero internet.
  static String? guessRegionOffline(double lat, double lon) {
    if (lat.abs() < 0.0001 && lon.abs() < 0.0001) return null;
    if (lat >= 33.0 && lat <= 38.7 && lon >= 124.5 && lon <= 130.0) {
      return 'South Korea';
    }
    if (lat >= 24.0 && lat <= 46.0 && lon >= 122.0 && lon <= 146.5) {
      return 'Japan';
    }
    if (lat >= 45.8 &&
        lat <= 47.85 &&
        lon >= 5.95 &&
        lon <= 10.5 &&
        !(lat < 46.15 && lon < 7.0)) {
      return 'Switzerland';
    }
    if (lat >= 46.3 && lat <= 49.1 && lon >= 9.5 && lon <= 17.2) {
      return 'Austria';
    }
    if (lat >= 41.3 && lat <= 51.1 && lon >= -5.2 && lon <= 9.6) {
      return 'France';
    }
    if (lat >= 47.2 && lat <= 55.1 && lon >= 5.8 && lon <= 15.1) {
      return 'Germany';
    }
    if (lat >= 36.0 && lat <= 43.8 && lon >= -9.3 && lon <= 4.3) {
      return 'Spain';
    }
    if (lat >= 36.6 && lat <= 47.1 && lon >= 6.6 && lon <= 18.6) {
      return 'Italy';
    }
    if (lat >= 49.8 && lat <= 60.9 && lon >= -10.5 && lon <= 1.8) {
      return 'United Kingdom';
    }
    if (lat >= 18.0 && lat <= 53.5 && lon >= 73.5 && lon <= 135.0) {
      return 'China';
    }
    if (lat >= 5.6 && lat <= 20.5 && lon >= 97.3 && lon <= 105.7) {
      return 'Thailand';
    }
    if (lat >= 8.5 && lat <= 23.4 && lon >= 102.1 && lon <= 109.5) {
      return 'Vietnam';
    }
    if (lat >= -33.8 && lat <= 5.3 && lon >= -74.0 && lon <= -34.7) {
      return 'Brazil';
    }
    if (lat >= 24.5 && lat <= 49.4 && lon >= -125.0 && lon <= -66.9) {
      return 'United States';
    }
    if (lat >= 41.7 && lat <= 83.1 && lon >= -141.0 && lon <= -52.6) {
      return 'Canada';
    }
    if (lat >= -43.7 && lat <= -10.6 && lon >= 113.0 && lon <= 154.0) {
      return 'Australia';
    }
    if (lat >= -47.3 && lat <= -34.0 && lon >= 166.0 && lon <= 179.0) {
      return 'New Zealand';
    }
    return null;
  }

  /// Extracts a concise human-readable overall position from a Nominatim
  /// reverse-geocode response (e.g. mountain/landmark, city, department/state, country).
  static String? formatOverallPlaceFromNominatim(Map<String, dynamic> data) {
    final address = (data['address'] as Map<String, dynamic>?) ?? const {};
    final category =
        (data['category'] ?? data['class'] ?? '').toString().toLowerCase();
    final type = (data['type'] ?? '').toString().toLowerCase();
    final topName = (data['name'] ?? '').toString().trim();

    String pickFirst(List<String> keys) {
      for (final k in keys) {
        final v = (address[k] ?? '').toString().trim();
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    final isGeographicFeature = category == 'natural' ||
        category == 'boundary' ||
        type == 'peak' ||
        type == 'mountain' ||
        type == 'volcano' ||
        type == 'national_park' ||
        type == 'nature_reserve' ||
        type == 'park';

    final landmark = pickFirst(const [
      'peak',
      'mountain',
      'mountain_pass',
      'volcano',
      'national_park',
      'nature_reserve',
      'protected_area',
      'natural',
    ]);
    final featureName = landmark.isNotEmpty
        ? landmark
        : (isGeographicFeature && topName.isNotEmpty ? topName : '');

    final locality = pickFirst(const [
      'city',
      'town',
      'village',
      'municipality',
      'hamlet',
      'suburb',
      'city_district',
      'borough',
    ]);
    final adminArea = pickFirst(const [
      'county',
      'state_district',
      'department',
      'state',
      'province',
      'region',
    ]);
    final country = pickFirst(const ['country']);
    final countryCode =
        (address['country_code'] ?? '').toString().trim().toUpperCase();

    final parts = <String>[];
    void addUnique(String value) {
      final clean = value.trim();
      if (clean.isEmpty) return;
      final lower = clean.toLowerCase();
      if (parts.any((p) => p.toLowerCase() == lower)) return;
      parts.add(clean);
    }

    addUnique(featureName);
    addUnique(locality);
    addUnique(adminArea);
    addUnique(country.isNotEmpty ? country : countryCode);

    if (parts.isEmpty) return null;
    return parts.take(4).join(', ');
  }

  /// Queries OpenStreetMap Nominatim when online to resolve the overall
  /// human-readable position (city, mountain, department/state, country).
  static Future<String?> resolveOverallPlaceOnline(
    double lat,
    double lon, {
    http.Client? client,
  }) async {
    if (lat.abs() < 0.0001 && lon.abs() < 0.0001) return null;
    // Cache at ~110 m resolution to avoid redundant Nominatim lookups.
    final cacheKey = '${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}';
    final cached = _overallPlaceCache[cacheKey];
    if (cached != null) return cached;

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?format=jsonv2&lat=${lat.toStringAsFixed(5)}'
        '&lon=${lon.toStringAsFixed(5)}&zoom=14&addressdetails=1',
      );
      final resp = await _getNominatim(uri, client: client);
      if (resp == null || resp.statusCode != 200) return null;
      final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final data = jsonDecode(bodyText) as Map<String, dynamic>;
      final formatted = formatOverallPlaceFromNominatim(data);
      if (formatted != null) {
        _putBounded(_overallPlaceCache, cacheKey, formatted);
      }
      return formatted;
    } catch (e) {
      debugPrint('[EdgeMapper] Overall place lookup skipped: $e');
      return null;
    }
  }

  /// Queries OpenStreetMap Nominatim when online to automatically guess what kind
  /// of walk/hike/park/street the user is on, its human-readable name, and the
  /// country's local language.
  static Future<LocationGuess?> guessFromCoordinatesOnline(
    double lat,
    double lon, {
    http.Client? client,
  }) async {
    if (lat.abs() < 0.0001 && lon.abs() < 0.0001) return null;
    // Cache at ~11 m resolution to avoid redundant Nominatim lookups.
    final cacheKey = '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}';
    final cached = _locationGuessCache[cacheKey];
    if (cached != null) return cached;

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?format=jsonv2&lat=${lat.toStringAsFixed(6)}'
        '&lon=${lon.toStringAsFixed(6)}&zoom=17&addressdetails=1',
      );
      final resp = await _getNominatim(uri, client: client);
      if (resp == null || resp.statusCode != 200) return null;
      final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final data = jsonDecode(bodyText) as Map<String, dynamic>;
      final guess = parseNominatimResponse(data, lat, lon);
      _putBounded(_locationGuessCache, cacheKey, guess);
      return guess;
    } catch (e) {
      debugPrint('[EdgeMapper] Online location guess skipped: $e');
      return null;
    }
  }

  /// Pure-Dart parser for Nominatim reverse-geocode JSON (unit-testable).
  static LocationGuess parseNominatimResponse(
    Map<String, dynamic> data,
    double lat,
    double lon,
  ) {
    final category = (data['category'] ?? data['class'] ?? '').toString().toLowerCase();
    final type = (data['type'] ?? '').toString().toLowerCase();
    final name = (data['name'] ?? '').toString().trim();
    final address = (data['address'] as Map<String, dynamic>?) ?? const {};
    final countryCode = (address['country_code'] ?? '').toString().toLowerCase();
    final countryLang = countryCode.isNotEmpty
        ? languageForCountryCode(countryCode)
        : guessCountryLanguageOffline(lat, lon);

    final parkName = (address['leisure'] ?? address['park'] ?? '').toString().trim();
    final roadName = (address['road'] ??
            address['footway'] ??
            address['pedestrian'] ??
            address['path'] ??
            '')
        .toString()
        .trim();
    final areaName = (address['suburb'] ??
            address['neighbourhood'] ??
            address['city'] ??
            address['town'] ??
            address['village'] ??
            '')
        .toString()
        .trim();
    final naturalName =
        (address['natural'] ?? address['peak'] ?? address['mountain'] ?? '')
            .toString()
            .trim();

    ActivityType activityType = ActivityType.urbanWalk;
    String highway = 'footway';
    String surface = 'paved';
    String routeSuffix = 'Walk';

    final combined = '$category $type $name $parkName $roadName $naturalName'
        .toLowerCase();

    if (category == 'leisure' &&
            (type == 'park' || type == 'garden' || type == 'nature_reserve') ||
        parkName.isNotEmpty ||
        combined.contains('park') ||
        combined.contains('parc') ||
        combined.contains('garden') ||
        combined.contains('公園')) {
      activityType = ActivityType.parkStroll;
      highway = 'footway';
      surface = 'compacted';
      routeSuffix = 'Park Stroll';
    } else if (category == 'natural' ||
        type == 'peak' ||
        type == 'wood' ||
        type == 'forest' ||
        type == 'mountain' ||
        combined.contains('mountain') ||
        combined.contains('trail') ||
        combined.contains('ridge') ||
        combined.contains('山') ||
        combined.contains('森')) {
      activityType = ActivityType.hiking;
      highway = 'path';
      surface = 'ground';
      routeSuffix = 'Trail Hike';
    } else if (type == 'cycleway') {
      activityType = ActivityType.cycling;
      highway = 'cycleway';
      surface = 'asphalt';
      routeSuffix = 'Bike Ride';
    } else if (type == 'steps') {
      activityType = ActivityType.stairway;
      highway = 'steps';
      surface = 'concrete';
      routeSuffix = 'Steps';
    } else if (type == 'track') {
      activityType = ActivityType.sharedTrack;
      highway = 'track';
      surface = 'gravel';
      routeSuffix = 'Track Walk';
    } else if (type == 'path' || type == 'bridleway') {
      activityType = ActivityType.natureWalk;
      highway = 'path';
      surface = 'dirt';
      routeSuffix = 'Nature Walk';
    } else if (type == 'pedestrian') {
      activityType = ActivityType.urbanWalk;
      highway = 'pedestrian';
      surface = 'paving_stones';
      routeSuffix = 'City Walk';
    }

    final primaryPlace = [
      if (parkName.isNotEmpty) parkName,
      if (naturalName.isNotEmpty) naturalName,
      if (name.isNotEmpty) name,
      if (roadName.isNotEmpty) roadName,
      if (areaName.isNotEmpty) areaName,
    ].firstWhere((s) => s.isNotEmpty, orElse: () => 'Local');

    final suggestedName = primaryPlace.toLowerCase().contains('park') ||
            primaryPlace.toLowerCase().contains('trail') ||
            primaryPlace.toLowerCase().contains('公園')
        ? '$primaryPlace Walk'
        : '$primaryPlace $routeSuffix';

    final contextParts = <String>[
      if (primaryPlace != 'Local') primaryPlace,
      if (areaName.isNotEmpty && areaName != primaryPlace) areaName,
      if (countryCode.isNotEmpty) countryCode.toUpperCase(),
    ];

    return LocationGuess(
      suggestedRouteName: suggestedName.trim(),
      activityType: activityType,
      highway: highway,
      surface: surface,
      countryCode: countryCode,
      countryLanguage: countryLang,
      locationContext: contextParts.join(', '),
    );
  }
}
