import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_env_config.dart';
import 'tile_disk_cache.dart';

enum MapTileStyle {
  osmStreets,
  topo,
  satellite;

  String get label => switch (this) {
        MapTileStyle.osmStreets => 'OSM Streets',
        MapTileStyle.topo => 'Hiking Topo',
        MapTileStyle.satellite => 'Satellite',
      };

  String get attribution => switch (this) {
        MapTileStyle.osmStreets => '© OpenStreetMap contributors',
        MapTileStyle.topo => '© OpenStreetMap • OpenTopoMap',
        MapTileStyle.satellite => '© Esri World Imagery',
      };

  String get cacheDirName => name;

  Uri tileUri(TileCoord coord) => tileCandidateUris(coord).first;

  /// Ordered primary + fallback tile URLs for live interactive map viewing.
  /// Uses OpenStreetMap Standard Carto (`tile.openstreetmap.org`) first for
  /// `osmStreets` because it renders full UTF-8 Unicode / Noto Sans CJK /
  /// Arabic / Thai / Cyrillic glyphs cleanly without CARTO Voyager's CJK
  /// mojibake/tofu rendering bug, while supporting CORS on Web.
  List<Uri> tileCandidateUris(TileCoord coord) {
    final sub = const ['a', 'b', 'c'][(coord.x + coord.y).abs() % 3];
    return switch (this) {
      MapTileStyle.osmStreets => [
          if (!kIsWeb)
            Uri.parse(
              'https://tile.openstreetmap.org/'
              '${coord.z}/${coord.x}/${coord.y}.png',
            ),
          // 1. OpenStreetMap France (full UTF-8 / CJK glyphs, allows Web referers, no API key)
          Uri.parse(
            'https://$sub.tile.openstreetmap.fr/osmfr/'
            '${coord.z}/${coord.x}/${coord.y}.png',
          ),
          // 2. Esri World Street Map (global CJK support, allows Web CORS/referers, no API key)
          Uri.parse(
            'https://server.arcgisonline.com/ArcGIS/rest/services/'
            'World_Street_Map/MapServer/tile/${coord.z}/${coord.y}/${coord.x}',
          ),
      ],
      MapTileStyle.topo => [
          Uri.parse(
            'https://$sub.tile.opentopomap.org/'
            '${coord.z}/${coord.x}/${coord.y}.png',
          ),
          Uri.parse(
            'https://tile.openstreetmap.org/'
            '${coord.z}/${coord.x}/${coord.y}.png',
          ),
        ],
      MapTileStyle.satellite => [
          Uri.parse(
            'https://server.arcgisonline.com/ArcGIS/rest/services/'
            'World_Imagery/MapServer/tile/${coord.z}/${coord.y}/${coord.x}',
          ),
          Uri.parse(
            'https://tile.openstreetmap.org/'
            '${coord.z}/${coord.x}/${coord.y}.png',
          ),
        ],
    };
  }

  /// Ordered candidate tile URLs safe for bulk offline area pre-downloading.
  ///
  /// Per OSMF Tile Usage Policy, bulk pre-downloading against
  /// `tile.openstreetmap.org` is strictly excluded. When a valid custom
  /// `OFFLINE_TILE_URL_TEMPLATE` is configured (and does not target an OSMF
  /// tile host), ONLY that dedicated provider is used for bulk downloads so
  /// rate-limit pauses retry cleanly against it instead of spilling large
  /// downloads onto shared public servers.
  List<Uri> bulkPrefetchCandidateUris(
    TileCoord coord, {
    String? customTileUrlTemplate,
  }) {
    final template =
        (customTileUrlTemplate ?? AppEnvConfig.offlineTileUrlTemplate).trim();
    if (template.isNotEmpty) {
      final customUri = OfflineTileService.resolveCustomTileUri(template, coord);
      if (customUri != null) {
        return [customUri];
      }
    }
    return [
      for (final candidate in tileCandidateUris(coord))
        if (!OfflineTileService.isOsmfTileHost(candidate.host)) candidate,
    ];
  }
}

class TileCoord {
  final int z;
  final int x;
  final int y;

  const TileCoord(this.z, this.x, this.y);

  @override
  bool operator ==(Object other) =>
      other is TileCoord && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => '$z/$x/$y';
}

class OfflineCacheStats {
  final int tileCount;
  final int totalBytes;

  const OfflineCacheStats({
    required this.tileCount,
    required this.totalBytes,
  });

  double get totalMb => totalBytes / (1024.0 * 1024.0);
}

class _TileFetchOutcome {
  final Uint8List? bytes;
  final Duration? retryAfter;
  final bool rateLimited;

  const _TileFetchOutcome({
    this.bytes,
    this.retryAfter,
    this.rateLimited = false,
  });
}

/// Manages OSM raster map tiles (OpenStreetMap Standard Carto with full global
/// Unicode/CJK font support for live viewing, plus Hiking Topo & Satellite)
/// with a persistent local disk cache so maps stay available offline during
/// hikes and walks.
///
/// Follows the OSMF Tile Usage Policy and polite bulk-downloading practices:
/// - Sends a valid app `User-Agent` with version and real contact URL.
/// - Limits live OSMF tile downloads to at most 2 concurrent connections.
/// - Never performs bulk region pre-downloading or background auto-prefetch
///   against `tile.openstreetmap.org`.
/// - Throttles bulk downloads to 2–4 concurrent requests with a small delay
///   between batches, caps offline zoom levels (<= 16) and tile counts
///   (conservatively capped for public fallbacks, up to 5,000–10,000 for a
///   configured paid/self-hosted `OFFLINE_TILE_URL_TEMPLATE`), and honors
///   HTTP `429 Too Many Requests` by pausing the queue for `Retry-After`
///   before retrying.
class OfflineTileService extends ChangeNotifier {
  static const int maxOsmfConcurrentRequests = 2;

  /// Offline zoom bounds — prevents exponential tile-count explosions at z17+.
  static const int minOfflineZoom = 1;
  static const int maxOfflineZoom = 16;

  /// Bulk concurrency bounds (2–4 parallel requests per batch).
  static const int minBulkConcurrency = 2;
  static const int defaultBulkConcurrency = 3;
  static const int maxBulkConcurrency = 4;

  /// Tile-count caps: tight caps for shared public fallbacks; 5,000 default /
  /// 10,000 hard ceiling for dedicated paid or self-hosted tile servers.
  static const int defaultMaxBulkTiles = 48;
  static const int hardMaxPublicBulkTiles = 60;
  static const int defaultCustomBulkTiles = 5000;
  static const int hardMaxCustomBulkTiles = 10000;
  static const int hardMaxBulkTiles = hardMaxPublicBulkTiles;

  static const double maxBulkRadiusKm = 2.0;
  static const double maxCustomBulkRadiusKm = 25.0;
  static const int maxAutoPrefetchTiles = 8;

  /// Polite delay between concurrent batches (50–100 ms for dedicated
  /// `OFFLINE_TILE_URL_TEMPLATE`, more conservative for public fallbacks).
  static const Duration defaultBulkBatchDelay = Duration(milliseconds: 75);
  static const Duration defaultPublicBulkBatchDelay =
      Duration(milliseconds: 250);
  static const Duration defaultBulkThrottleDelay = defaultBulkBatchDelay;
  static const Duration defaultAutoPrefetchThrottleDelay =
      Duration(milliseconds: 600);

  /// Maximum retries per rate-limited tile and consecutive 429 queue pauses.
  static const int maxRateLimitRetriesPerTile = 2;
  static const int maxConsecutiveRateLimitPauses = 3;

  static String get userAgent =>
      AppEnvConfig.httpUserAgent(component: 'Tiles');

  /// Returns `true` for OSMF-operated tile hosts (`tile.openstreetmap.org`
  /// and legacy `{a,b,c}.tile.openstreetmap.org`).
  static bool isOsmfTileHost(String host) {
    final lower = host.trim().toLowerCase();
    return lower == 'tile.openstreetmap.org' ||
        lower.endsWith('.tile.openstreetmap.org');
  }

  /// Resolves a custom `{z}/{x}/{y}` (optional `{s}`) raster tile URL template
  /// for bulk offline pre-downloading. Returns `null` if invalid or if it
  /// targets an OSMF tile server (which prohibits bulk pre-downloading).
  static Uri? resolveCustomTileUri(String template, TileCoord coord) {
    final trimmed = template.trim();
    if (trimmed.isEmpty) return null;
    if (!trimmed.contains('{z}') ||
        !trimmed.contains('{x}') ||
        !trimmed.contains('{y}')) {
      return null;
    }
    final sub = const ['a', 'b', 'c'][(coord.x + coord.y).abs() % 3];
    final rendered = trimmed
        .replaceAll('{s}', sub)
        .replaceAll('{z}', '${coord.z}')
        .replaceAll('{x}', '${coord.x}')
        .replaceAll('{y}', '${coord.y}');
    final uri = Uri.tryParse(rendered);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    final isLoopback = uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        uri.host == '::1';
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && isLoopback)) {
      return null;
    }
    if (isOsmfTileHost(uri.host)) {
      return null;
    }
    return uri;
  }

  /// Filters and sorts zoom levels to safe offline bounds (`minOfflineZoom`..[maxZoom]).
  static List<int> sanitizeOfflineZoomLevels(
    List<int> zoomLevels, {
    int maxZoom = maxOfflineZoom,
  }) {
    final cappedMax = maxZoom.clamp(minOfflineZoom, maxOfflineZoom);
    final sanitized = zoomLevels
        .where((z) => z >= minOfflineZoom && z <= cappedMax)
        .toSet()
        .toList()
      ..sort();
    return sanitized.isEmpty ? const [13, 14, 15] : sanitized;
  }

  /// Parses an HTTP `Retry-After` header (delta-seconds or RFC-1123 date) and
  /// clamps the resulting backoff duration safely between 1s and 300s.
  static Duration parseRetryAfter(
    String? rawHeader, {
    required DateTime now,
    Duration fallback = const Duration(seconds: 30),
  }) {
    final raw = rawHeader?.trim();
    if (raw == null || raw.isEmpty) return fallback;
    final seconds = int.tryParse(raw);
    if (seconds != null) {
      return Duration(seconds: seconds.clamp(1, 300));
    }
    final parsedDate = _parseHttpDate(raw);
    if (parsedDate != null) {
      final diffSec = parsedDate.difference(now.toUtc()).inSeconds;
      if (diffSec > 0) {
        return Duration(seconds: diffSec.clamp(1, 300));
      }
    }
    return fallback;
  }

  static DateTime? _parseHttpDate(String raw) {
    // Handles IMF-fixdate / RFC 1123 e.g. "Wed, 21 Oct 2026 07:28:00 GMT"
    final match = RegExp(
      r'^[A-Za-z]{3},\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$',
    ).firstMatch(raw);
    if (match == null) return null;
    const months = {
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    final month = months[match.group(2)!.toLowerCase()];
    if (month == null) return null;
    return DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  final TileDiskCache _diskCache;
  final http.Client _client;
  final bool _ownsClient;
  final String? _customTileUrlTemplate;
  final int _bulkConcurrency;
  final Duration? _bulkThrottleDelay;
  final Duration _autoPrefetchThrottleDelay;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;

  MapTileStyle _style = MapTileStyle.osmStreets;
  final Map<String, Uint8List> _memCache = {};
  final Map<String, Future<_TileFetchOutcome>> _inFlight = {};
  final Map<String, DateTime> _failedUntil = {};
  final Map<String, DateTime> _hostBackoffUntil = {};
  final Queue<Completer<void>> _osmfWaiters = Queue<Completer<void>>();
  int _osmfActiveRequests = 0;

  bool _isDownloadingRegion = false;
  bool _isRateLimitPaused = false;
  bool _cancelDownloadRequested = false;
  int _downloadDone = 0;
  int _downloadTotal = 0;
  int _cachedTileCount = 0;
  int _cachedBytes = 0;
  int _cacheEpoch = 0;
  String? _lastPrefetchKey;
  String? _lastDownloadWarning;

  OfflineTileService({
    http.Client? client,
    TileDiskCache? diskCache,
    String? customTileUrlTemplate,
    int bulkConcurrency = defaultBulkConcurrency,
    Duration? bulkThrottleDelay,
    Duration autoPrefetchThrottleDelay = defaultAutoPrefetchThrottleDelay,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _diskCache = diskCache ?? createTileDiskCache(),
        _customTileUrlTemplate = customTileUrlTemplate,
        _bulkConcurrency =
            bulkConcurrency.clamp(minBulkConcurrency, maxBulkConcurrency),
        _bulkThrottleDelay = bulkThrottleDelay,
        _autoPrefetchThrottleDelay = autoPrefetchThrottleDelay,
        _clock = clock ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed;

  MapTileStyle get style => _style;
  bool get isDownloadingRegion => _isDownloadingRegion;
  bool get isRateLimitPaused => _isRateLimitPaused;
  int get downloadDone => _downloadDone;
  int get downloadTotal => _downloadTotal;
  int get cacheEpoch => _cacheEpoch;
  String? get lastDownloadWarning => _lastDownloadWarning;
  int get bulkConcurrency => _bulkConcurrency;

  /// Whether a valid non-OSMF custom `OFFLINE_TILE_URL_TEMPLATE` is configured
  /// for dedicated bulk offline downloads.
  bool get hasCustomBulkTileProvider {
    final template =
        (_customTileUrlTemplate ?? AppEnvConfig.offlineTileUrlTemplate).trim();
    return resolveCustomTileUri(template, const TileCoord(1, 0, 0)) != null;
  }

  /// Cancels an active (or rate-limit-paused) offline region download cleanly.
  void cancelRegionDownload() {
    if (_isDownloadingRegion) {
      _cancelDownloadRequested = true;
      notifyListeners();
    }
  }

  bool isHostBackedOff(String host) {
    final until = _hostBackoffUntil[host.toLowerCase()];
    if (until == null) return false;
    if (until.isAfter(_clock())) return true;
    _hostBackoffUntil.remove(host.toLowerCase());
    return false;
  }

  Duration? _remainingHostBackoff(String host) {
    final until = _hostBackoffUntil[host.toLowerCase()];
    if (until == null) return null;
    final remaining = until.difference(_clock());
    if (remaining > Duration.zero) return remaining;
    _hostBackoffUntil.remove(host.toLowerCase());
    return null;
  }

  /// Validates PNG, JPEG, or WebP magic bytes so HTML/text error responses
  /// can never corrupt the offline tile cache.
  static bool isValidRasterTileBytes(Uint8List bytes) {
    if (bytes.length < 12) return false;
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true;
    }
    // WebP: RIFF....WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    return false;
  }

  double get downloadProgress =>
      _downloadTotal > 0 ? (_downloadDone / _downloadTotal).clamp(0.0, 1.0) : 0.0;
  OfflineCacheStats get cacheStats =>
      OfflineCacheStats(tileCount: _cachedTileCount, totalBytes: _cachedBytes);

  void setStyle(MapTileStyle nextStyle) {
    if (_style == nextStyle) return;
    _style = nextStyle;
    _lastPrefetchKey = null;
    notifyListeners();
  }

  void toggleStyle() {
    final values = MapTileStyle.values;
    final nextIdx = (values.indexOf(_style) + 1) % values.length;
    setStyle(values[nextIdx]);
  }

  Future<void> init() async {
    try {
      await _diskCache.init();
      await refreshCacheStats();
    } catch (e) {
      debugPrint('[EdgeMapper] OfflineTileService init warning: $e');
    }
  }

  @override
  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
    super.dispose();
  }

  /// Standard Web Mercator projection: lat/lon -> fractional tile X/Y at zoom [z].
  static (double, double) latLonToTileFractional(
    double lat,
    double lon,
    int z,
  ) {
    final clampedLat = lat.clamp(-85.05112878, 85.05112878);
    final n = math.pow(2.0, z).toDouble();
    final x = (lon + 180.0) / 360.0 * n;
    final latRad = clampedLat * math.pi / 180.0;
    final y = (1.0 -
            math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
        2.0 *
        n;
    return (x, y);
  }

  static TileCoord latLonToTile(double lat, double lon, int z) {
    final (fx, fy) = latLonToTileFractional(lat, lon, z);
    final maxTile = (1 << z) - 1;
    return TileCoord(
      z,
      fx.floor().clamp(0, maxTile),
      fy.floor().clamp(0, maxTile),
    );
  }

  /// Computes OSM tiles within [radiusKm] of ([centerLat], [centerLon])
  /// across the requested [zoomLevels], strictly capping zoom levels to
  /// `<= maxOfflineZoom` (16) and tile counts to `<= hardMaxCustomBulkTiles` (10,000).
  static List<TileCoord> tilesForRadius({
    required double centerLat,
    required double centerLon,
    required double radiusKm,
    List<int> zoomLevels = const [13, 14, 15],
    int maxTiles = defaultMaxBulkTiles,
    int maxZoom = maxOfflineZoom,
    double maxRadiusKm = maxCustomBulkRadiusKm,
  }) {
    final safeMaxTiles = maxTiles.clamp(1, hardMaxCustomBulkTiles);
    final safeRadiusKm = radiusKm.clamp(0.1, maxRadiusKm);
    final safeZoomLevels = sanitizeOfflineZoomLevels(
      zoomLevels,
      maxZoom: maxZoom,
    );
    final latDelta = safeRadiusKm / 111.32;
    final cosLat = math.max(math.cos(centerLat * math.pi / 180.0).abs(), 0.2);
    final lonDelta = safeRadiusKm / (111.32 * cosLat);

    final minLat = (centerLat - latDelta).clamp(-85.0, 85.0);
    final maxLat = (centerLat + latDelta).clamp(-85.0, 85.0);
    final minLon = (centerLon - lonDelta).clamp(-180.0, 180.0);
    final maxLon = (centerLon + lonDelta).clamp(-180.0, 180.0);

    final result = <TileCoord>[];
    for (final z in safeZoomLevels) {
      final topLeft = latLonToTile(maxLat, minLon, z);
      final bottomRight = latLonToTile(minLat, maxLon, z);
      for (int x = topLeft.x; x <= bottomRight.x; x++) {
        for (int y = topLeft.y; y <= bottomRight.y; y++) {
          result.add(TileCoord(z, x, y));
          if (result.length >= safeMaxTiles) return result;
        }
      }
    }
    return result;
  }

  String _memKey(MapTileStyle style, TileCoord coord) =>
      '${style.cacheDirName}/$coord';

  Future<void> _acquireOsmfSlot() async {
    if (_osmfActiveRequests < maxOsmfConcurrentRequests) {
      _osmfActiveRequests++;
      return;
    }
    final waiter = Completer<void>();
    _osmfWaiters.addLast(waiter);
    await waiter.future;
  }

  void _releaseOsmfSlot() {
    if (_osmfWaiters.isNotEmpty) {
      _osmfWaiters.removeFirst().complete();
      return;
    }
    _osmfActiveRequests = math.max(0, _osmfActiveRequests - 1);
  }

  bool _allBulkCandidatesBackedOff(MapTileStyle activeStyle, TileCoord probe) {
    final candidates = activeStyle.bulkPrefetchCandidateUris(
      probe,
      customTileUrlTemplate: _customTileUrlTemplate,
    );
    if (candidates.isEmpty) return true;
    return candidates.every((uri) => isHostBackedOff(uri.host));
  }

  /// Loads a tile from memory or disk cache first. If missing and [allowNetwork]
  /// is true, downloads it from the active tile server and caches it.
  ///
  /// When [forBulkPrefetch] is `true`, `tile.openstreetmap.org` is strictly
  /// skipped per OSMF Tile Usage Policy and non-OSMF / configured bulk tile
  /// providers are used instead.
  Future<Uint8List?> getTile(
    TileCoord coord, {
    required bool allowNetwork,
    MapTileStyle? styleOverride,
    bool forBulkPrefetch = false,
  }) async {
    final outcome = await _fetchTileOutcome(
      coord,
      allowNetwork: allowNetwork,
      styleOverride: styleOverride,
      forBulkPrefetch: forBulkPrefetch,
    );
    return outcome.bytes;
  }

  Future<_TileFetchOutcome> _fetchTileOutcome(
    TileCoord coord, {
    required bool allowNetwork,
    MapTileStyle? styleOverride,
    bool forBulkPrefetch = false,
  }) async {
    final activeStyle = styleOverride ?? _style;
    final key = _memKey(activeStyle, coord);
    final mem = _memCache[key];
    if (mem != null) return _TileFetchOutcome(bytes: mem);

    final diskBytes = await _diskCache.readTile(
      activeStyle.cacheDirName,
      coord.z,
      coord.x,
      coord.y,
    );
    if (diskBytes != null && isValidRasterTileBytes(diskBytes)) {
      _putMem(key, diskBytes);
      return _TileFetchOutcome(bytes: diskBytes);
    }

    if (!allowNetwork) return const _TileFetchOutcome();

    final now = _clock();
    final failedAt = _failedUntil[key];
    if (failedAt != null && failedAt.isAfter(now)) {
      return const _TileFetchOutcome();
    }

    final candidates = forBulkPrefetch
        ? activeStyle.bulkPrefetchCandidateUris(
            coord,
            customTileUrlTemplate: _customTileUrlTemplate,
          )
        : activeStyle.tileCandidateUris(coord);
    if (candidates.isEmpty) return const _TileFetchOutcome();

    return _inFlight.putIfAbsent(key, () async {
      bool sawRateLimit = false;
      Duration? longestRetryAfter;
      try {
        for (final uri in candidates) {
          if (forBulkPrefetch && isOsmfTileHost(uri.host)) {
            continue;
          }
          final activeBackoff = _remainingHostBackoff(uri.host);
          if (activeBackoff != null) {
            sawRateLimit = true;
            if (longestRetryAfter == null ||
                activeBackoff > longestRetryAfter) {
              longestRetryAfter = activeBackoff;
            }
            continue;
          }

          final isOsmf = isOsmfTileHost(uri.host);
          if (isOsmf) {
            await _acquireOsmfSlot();
          }
          try {
            final resp = await _client
                .get(
                  uri,
                  headers: kIsWeb ? null : {'User-Agent': userAgent},
                )
                .timeout(const Duration(seconds: 7));

            if (resp.statusCode == 429 || resp.statusCode == 503) {
              final backoff = parseRetryAfter(
                resp.headers['retry-after'],
                now: _clock(),
                fallback: Duration(
                  seconds: resp.statusCode == 429 ? 30 : 20,
                ),
              );
              _hostBackoffUntil[uri.host.toLowerCase()] = _clock().add(backoff);
              sawRateLimit = true;
              if (longestRetryAfter == null || backoff > longestRetryAfter) {
                longestRetryAfter = backoff;
              }
              debugPrint(
                '[EdgeMapper] Tile host ${uri.host} returned HTTP '
                '${resp.statusCode}; backing off for ${backoff.inSeconds}s.',
              );
              continue;
            }

            if (resp.statusCode == 403 || resp.statusCode == 418) {
              _hostBackoffUntil[uri.host.toLowerCase()] =
                  _clock().add(const Duration(minutes: 5));
              debugPrint(
                '[EdgeMapper] Tile host ${uri.host} blocked request '
                '(HTTP ${resp.statusCode}); backing off 5m.',
              );
              continue;
            }

            final contentType = resp.headers['content-type'] ?? '';
            if (resp.statusCode == 200 &&
                isValidRasterTileBytes(resp.bodyBytes) &&
                (contentType.contains('image') || contentType.isEmpty)) {
              final bytes = resp.bodyBytes;
              _failedUntil.remove(key);
              _putMem(key, bytes);
              await _diskCache.writeTile(
                activeStyle.cacheDirName,
                coord.z,
                coord.x,
                coord.y,
                bytes,
              );
              _cachedTileCount++;
              _cachedBytes += bytes.length;
              return _TileFetchOutcome(bytes: bytes);
            }
          } catch (e) {
            final safeEndpoint = '${uri.scheme}://${uri.host}${uri.path}';
            debugPrint('[EdgeMapper] Tile $key ($safeEndpoint) skipped: $e');
          } finally {
            if (isOsmf) {
              _releaseOsmfSlot();
            }
          }
        }
        if (sawRateLimit) {
          return _TileFetchOutcome(
            rateLimited: true,
            retryAfter: longestRetryAfter ?? const Duration(seconds: 30),
          );
        }
        _failedUntil[key] = _clock().add(const Duration(seconds: 60));
      } finally {
        _inFlight.remove(key);
      }
      return const _TileFetchOutcome();
    });
  }

  void _putMem(String key, Uint8List bytes) {
    if (_memCache.length > 160) {
      _memCache.remove(_memCache.keys.first);
    }
    _memCache[key] = bytes;
  }

  /// Checks whether at least one local tile around ([lat], [lon]) at zoom 13–16
  /// is already cached offline on disk.
  Future<bool> hasOfflineCoverageAt(double lat, double lon) async {
    for (final z in const [15, 14, 16, 13]) {
      final coord = latLonToTile(lat, lon, z);
      if (_memCache.containsKey(_memKey(_style, coord))) return true;
      if (await _diskCache.hasTile(
        _style.cacheDirName,
        coord.z,
        coord.x,
        coord.y,
      )) {
        return true;
      }
    }
    return false;
  }

  /// Conservatively caches the immediate neighborhood (~350m, zoom 14–15,
  /// max 8 tiles, strictly non-OSMF / configured bulk provider) when the user
  /// explicitly opts into auto-caching nearby tiles.
  Future<void> autoPrefetchSurrounding({
    required double lat,
    required double lon,
    required bool isOnline,
  }) async {
    if (!isOnline || _isDownloadingRegion || kIsWeb) return;
    if (lat.abs() < 0.0001 && lon.abs() < 0.0001) return;

    final cellKey =
        '${_style.cacheDirName}_${(lat * 150).round()}_${(lon * 150).round()}';
    if (_lastPrefetchKey == cellKey) return;
    _lastPrefetchKey = cellKey;

    final tiles = tilesForRadius(
      centerLat: lat,
      centerLon: lon,
      radiusKm: 0.35,
      zoomLevels: const [14, 15],
      maxTiles: maxAutoPrefetchTiles,
      maxRadiusKm: maxBulkRadiusKm,
    );

    for (final tile in tiles) {
      if (_allBulkCandidatesBackedOff(_style, tile)) {
        break;
      }
      if (await _diskCache.hasTile(
        _style.cacheDirName,
        tile.z,
        tile.x,
        tile.y,
      )) {
        continue;
      }
      await getTile(tile, allowNetwork: true, forBulkPrefetch: true);
      if (_autoPrefetchThrottleDelay > Duration.zero) {
        await _sleep(_autoPrefetchThrottleDelay);
      }
    }
    notifyListeners();
  }

  /// Downloads a rate-limited, capped offline map package around
  /// ([centerLat], [centerLon]) using `OFFLINE_TILE_URL_TEMPLATE` or non-OSMF
  /// tile servers (never `tile.openstreetmap.org`):
  /// - Caps zoom levels to `<= 16` (`maxOfflineZoom`) and tile counts to safe
  ///   bounds (`48`–`60` on shared public fallbacks; `5,000`–`10,000` on a
  ///   configured dedicated `OFFLINE_TILE_URL_TEMPLATE`).
  /// - Throttles parallel downloads to `2`–`4` concurrent requests per batch
  ///   with a polite inter-batch delay (`75 ms` default for dedicated servers).
  /// - Honors HTTP `429 Too Many Requests` by reading `Retry-After`, pausing
  ///   the queue for that duration, and retrying the rate-limited tiles.
  Future<int> downloadRegion({
    required double centerLat,
    required double centerLon,
    required double radiusKm,
    List<int> zoomLevels = const [13, 14, 15],
    int? maxTiles,
    int maxZoom = maxOfflineZoom,
  }) async {
    if (_isDownloadingRegion) return 0;

    final isCustom = hasCustomBulkTileProvider;
    final maxAllowedRadius =
        isCustom ? maxCustomBulkRadiusKm : maxBulkRadiusKm;
    final maxAllowedTiles =
        isCustom ? hardMaxCustomBulkTiles : hardMaxPublicBulkTiles;
    final defaultTileCap =
        isCustom ? defaultCustomBulkTiles : defaultMaxBulkTiles;

    final safeRadius = radiusKm.clamp(0.2, maxAllowedRadius);
    final safeMaxTiles =
        (maxTiles ?? defaultTileCap).clamp(1, maxAllowedTiles);
    final effectiveConcurrency = isCustom
        ? _bulkConcurrency
        : math.min(_bulkConcurrency, minBulkConcurrency);
    final effectiveBatchDelay = _bulkThrottleDelay ??
        (isCustom ? defaultBulkBatchDelay : defaultPublicBulkBatchDelay);

    final tiles = tilesForRadius(
      centerLat: centerLat,
      centerLon: centerLon,
      radiusKm: safeRadius,
      zoomLevels: zoomLevels,
      maxTiles: safeMaxTiles,
      maxZoom: maxZoom,
      maxRadiusKm: maxAllowedRadius,
    );

    _isDownloadingRegion = true;
    _isRateLimitPaused = false;
    _cancelDownloadRequested = false;
    _downloadDone = 0;
    _downloadTotal = tiles.length;
    _lastDownloadWarning = null;
    notifyListeners();

    int fetched = 0;
    final pending = Queue<TileCoord>.from(tiles);
    final retriesByTile = <TileCoord, int>{};
    int consecutiveRateLimitPauses = 0;

    try {
      while (pending.isNotEmpty && !_cancelDownloadRequested) {
        // Fill a bounded concurrent batch of uncached tiles.
        final batch = <TileCoord>[];
        while (pending.isNotEmpty &&
            batch.length < effectiveConcurrency &&
            !_cancelDownloadRequested) {
          final tile = pending.removeFirst();
          if (await _diskCache.hasTile(
            _style.cacheDirName,
            tile.z,
            tile.x,
            tile.y,
          )) {
            fetched++;
            _downloadDone++;
            continue;
          }
          batch.add(tile);
        }

        if (batch.isEmpty) {
          notifyListeners();
          continue;
        }

        final outcomes = await Future.wait(
          batch.map(
            (tile) => _fetchTileOutcome(
              tile,
              allowNetwork: true,
              forBulkPrefetch: true,
            ),
          ),
        );

        Duration? batchRetryAfter;
        final rateLimitedToRetry = <TileCoord>[];
        bool anySucceededInBatch = false;

        for (int i = 0; i < batch.length; i++) {
          final tile = batch[i];
          final outcome = outcomes[i];
          if (outcome.bytes != null) {
            fetched++;
            _downloadDone++;
            anySucceededInBatch = true;
          } else if (outcome.rateLimited) {
            final attempts = retriesByTile[tile] ?? 0;
            if (attempts < maxRateLimitRetriesPerTile) {
              retriesByTile[tile] = attempts + 1;
              rateLimitedToRetry.add(tile);
              final retryDelay =
                  outcome.retryAfter ?? const Duration(seconds: 30);
              if (batchRetryAfter == null || retryDelay > batchRetryAfter) {
                batchRetryAfter = retryDelay;
              }
            } else {
              _downloadDone++;
              _lastDownloadWarning =
                  'Tile server rate limit (HTTP 429) persisted after retries. '
                  'Cached $fetched of $_downloadTotal tiles.';
            }
          } else {
            _downloadDone++;
          }
        }

        if (rateLimitedToRetry.isNotEmpty && !_cancelDownloadRequested) {
          consecutiveRateLimitPauses++;
          if (consecutiveRateLimitPauses > maxConsecutiveRateLimitPauses) {
            _lastDownloadWarning =
                'Tile server remained rate-limited (HTTP 429) after '
                '$maxConsecutiveRateLimitPauses pauses. Cached $fetched of '
                '$_downloadTotal tiles.';
            break;
          }

          // Re-queue rate-limited tiles at the front in their original order.
          for (int i = rateLimitedToRetry.length - 1; i >= 0; i--) {
            pending.addFirst(rateLimitedToRetry[i]);
          }

          final pause = batchRetryAfter ?? const Duration(seconds: 30);
          _isRateLimitPaused = true;
          _lastDownloadWarning =
              'Rate limited (HTTP 429). Pausing queue for ${pause.inSeconds}s '
              'before retrying...';
          notifyListeners();

          await _sleep(pause);

          _isRateLimitPaused = false;
          // Clear expired (or just-awaited) host backoffs before retrying.
          final nowAfterPause = _clock().add(const Duration(milliseconds: 50));
          _hostBackoffUntil.removeWhere((_, until) => !until.isAfter(nowAfterPause));
          notifyListeners();
        } else {
          if (anySucceededInBatch) {
            consecutiveRateLimitPauses = 0;
            if (_lastDownloadWarning != null &&
                _lastDownloadWarning!.startsWith('Rate limited')) {
              _lastDownloadWarning = null;
            }
          }
          notifyListeners();
          if (pending.isNotEmpty &&
              !_cancelDownloadRequested &&
              effectiveBatchDelay > Duration.zero) {
            await _sleep(effectiveBatchDelay);
          }
        }
      }
    } finally {
      _isDownloadingRegion = false;
      _isRateLimitPaused = false;
      _cancelDownloadRequested = false;
      await refreshCacheStats();
      notifyListeners();
    }
    return fetched;
  }

  Future<void> refreshCacheStats() async {
    try {
      final (count, bytes) = await _diskCache.computeStats();
      _cachedTileCount = count;
      _cachedBytes = bytes;
    } catch (_) {
      _cachedTileCount = 0;
      _cachedBytes = 0;
    }
    notifyListeners();
  }

  Future<void> clearCache() async {
    _memCache.clear();
    _failedUntil.clear();
    _hostBackoffUntil.clear();
    _lastPrefetchKey = null;
    _lastDownloadWarning = null;
    _cacheEpoch++;
    try {
      await _diskCache.clear();
    } catch (_) {}
    await refreshCacheStats();
  }
}
