import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:edge_mapper/services/app_env_config.dart';
import 'package:edge_mapper/services/location_context_service.dart';
import 'package:edge_mapper/services/offline_tile_service.dart';
import 'package:edge_mapper/services/osm_export_service.dart';
import 'package:edge_mapper/services/osm_publish_service.dart';
import 'package:edge_mapper/services/tile_disk_cache.dart';

class _InMemoryTileDiskCache implements TileDiskCache {
  final Map<String, Uint8List> _store = {};

  String _k(String styleDir, int z, int x, int y) => '$styleDir/$z/$x/$y';

  @override
  Future<void> init() async {}

  @override
  Future<Uint8List?> readTile(String styleDir, int z, int x, int y) async =>
      _store[_k(styleDir, z, x, y)];

  @override
  Future<bool> hasTile(String styleDir, int z, int x, int y) async =>
      _store.containsKey(_k(styleDir, z, x, y));

  @override
  Future<void> writeTile(
    String styleDir,
    int z,
    int x,
    int y,
    Uint8List bytes,
  ) async {
    _store[_k(styleDir, z, x, y)] = bytes;
  }

  @override
  Future<(int count, int bytes)> computeStats() async {
    int total = 0;
    for (final v in _store.values) {
      total += v.length;
    }
    return (_store.length, total);
  }

  @override
  Future<void> clear() async => _store.clear();
}

final Uint8List _validPngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
]);

void main() {
  group('Version Sync & OSMF User-Agent Policy Compliance', () {
    test('AppEnvConfig.appVersion matches pubspec.yaml and all OSM/GPX generators', () {
      final pubspecText = File('pubspec.yaml').readAsStringSync();
      final match = RegExp(
        r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)',
        multiLine: true,
      ).firstMatch(pubspecText);
      expect(match, isNotNull);
      final pubspecVersion = match!.group(1)!;

      expect(AppEnvConfig.appVersion, equals(pubspecVersion));
      expect(AppEnvConfig.osmGenerator, equals('Edge Mapper $pubspecVersion'));
      expect(
        OsmExportService.buildOsmXml(),
        contains('generator="Edge Mapper $pubspecVersion"'),
      );
      expect(
        OsmExportService.buildGpx(),
        contains('creator="Edge Mapper $pubspecVersion"'),
      );
      expect(
        OsmPublishService.buildChangesetXml(comment: 'Test'),
        contains('v="Edge Mapper $pubspecVersion"'),
      );
      expect(
        OsmPublishService.buildOsmChangeXml(changesetId: 1),
        contains('generator="Edge Mapper $pubspecVersion"'),
      );
    });

    test('User-Agent uses synced version and real contact URL (never openstreetmap.org)', () {
      final tileUa = OfflineTileService.userAgent;
      final nominatimUa = LocationContextService.userAgent;

      expect(tileUa, startsWith('EdgeMapper/${AppEnvConfig.appVersion} ('));
      expect(nominatimUa, startsWith('EdgeMapper/${AppEnvConfig.appVersion} ('));
      expect(tileUa.toLowerCase(), isNot(contains('openstreetmap.org')));
      expect(nominatimUa.toLowerCase(), isNot(contains('openstreetmap.org')));

      // Custom contact URL is honored
      final customUa = AppEnvConfig.httpUserAgent(
        component: 'Tiles',
        contactOverride: 'https://github.com/example/edge-mapper',
      );
      expect(customUa, contains('+https://github.com/example/edge-mapper'));
      expect(customUa, contains('Tiles'));

      // openstreetmap.org contact override is rejected cleanly
      final rejectedOsmContact = AppEnvConfig.httpUserAgent(
        contactOverride: 'https://openstreetmap.org',
      );
      expect(
        rejectedOsmContact.toLowerCase(),
        isNot(contains('openstreetmap.org')),
      );
    });
  });

  group('OSMF Tile Usage Policy — Live Viewing vs Bulk Pre-Download', () {
    test('live getTile uses tile.openstreetmap.org with compliant User-Agent', () async {
      final requestedUris = <Uri>[];
      final requestedUserAgents = <String?>[];
      final mockClient = MockClient((req) async {
        requestedUris.add(req.url);
        requestedUserAgents.add(req.headers['User-Agent']);
        return http.Response.bytes(
          _validPngBytes,
          200,
          headers: {'content-type': 'image/png'},
        );
      });

      final service = OfflineTileService(
        client: mockClient,
        diskCache: _InMemoryTileDiskCache(),
        bulkThrottleDelay: Duration.zero,
      );

      final bytes = await service.getTile(
        const TileCoord(15, 29106, 12903),
        allowNetwork: true,
      );

      expect(bytes, isNotNull);
      expect(requestedUris, hasLength(1));
      expect(requestedUris.first.host, equals('tile.openstreetmap.org'));
      expect(requestedUserAgents.first, equals(OfflineTileService.userAgent));
      expect(
        requestedUserAgents.first!.toLowerCase(),
        isNot(contains('openstreetmap.org')),
      );
    });

    test('bulkPrefetchCandidateUris excludes all OSMF hosts and supports custom template', () {
      const coord = TileCoord(15, 29106, 12903);

      for (final style in MapTileStyle.values) {
        final bulkUris = style.bulkPrefetchCandidateUris(coord);
        expect(bulkUris, isNotEmpty);
        for (final uri in bulkUris) {
          expect(OfflineTileService.isOsmfTileHost(uri.host), isFalse);
        }
      }

      // Custom non-OSMF tile template is prioritized first
      final customBulk = MapTileStyle.osmStreets.bulkPrefetchCandidateUris(
        coord,
        customTileUrlTemplate: 'https://{s}.tiles.example.org/{z}/{x}/{y}.png',
      );
      expect(customBulk.first.host, endsWith('tiles.example.org'));
      expect(customBulk.first.path, equals('/15/29106/12903.png'));

      // Custom template pointing to OSMF tile server is rejected
      expect(
        OfflineTileService.resolveCustomTileUri(
          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          coord,
        ),
        isNull,
      );
      expect(
        OfflineTileService.resolveCustomTileUri(
          'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
          coord,
        ),
        isNull,
      );
    });

    test('downloadRegion and autoPrefetchSurrounding NEVER hit tile.openstreetmap.org and obey caps', () async {
      final requestedHosts = <String>[];
      final mockClient = MockClient((req) async {
        requestedHosts.add(req.url.host);
        return http.Response.bytes(
          _validPngBytes,
          200,
          headers: {'content-type': 'image/png'},
        );
      });

      final service = OfflineTileService(
        client: mockClient,
        diskCache: _InMemoryTileDiskCache(),
        bulkThrottleDelay: Duration.zero,
        autoPrefetchThrottleDelay: Duration.zero,
      );

      // Even with huge requested radius/maxTiles, downloadRegion is conservatively capped
      final fetched = await service.downloadRegion(
        centerLat: 35.6812,
        centerLon: 139.7671,
        radiusKm: 10.0,
        zoomLevels: const [13, 14, 15],
        maxTiles: 500,
      );

      expect(fetched, greaterThan(0));
      expect(fetched, lessThanOrEqualTo(OfflineTileService.hardMaxBulkTiles));
      expect(requestedHosts, isNotEmpty);
      expect(
        requestedHosts.any(OfflineTileService.isOsmfTileHost),
        isFalse,
      );

      // Auto-prefetch also strictly avoids OSMF tile hosts and caps at 8 tiles
      requestedHosts.clear();
      await service.clearCache();
      await service.autoPrefetchSurrounding(
        lat: 35.6812,
        lon: 139.7671,
        isOnline: true,
      );
      expect(requestedHosts.length, lessThanOrEqualTo(OfflineTileService.maxAutoPrefetchTiles));
      expect(
        requestedHosts.any(OfflineTileService.isOsmfTileHost),
        isFalse,
      );
    });

    test('throttles bulk concurrency to 2-4 parallel requests with inter-batch delay', () async {
      int active = 0;
      int peakActive = 0;
      final recordedSleeps = <Duration>[];

      final mockClient = MockClient((req) async {
        active++;
        if (active > peakActive) peakActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return http.Response.bytes(
          _validPngBytes,
          200,
          headers: {'content-type': 'image/png'},
        );
      });

      final service = OfflineTileService(
        client: mockClient,
        diskCache: _InMemoryTileDiskCache(),
        customTileUrlTemplate: 'https://tiles.example.org/{z}/{x}/{y}.png',
        bulkConcurrency: 3,
        sleep: (d) async => recordedSleeps.add(d),
      );

      // Concurrency clamping enforces 2..4 bounds
      expect(
        OfflineTileService(bulkConcurrency: 1).bulkConcurrency,
        equals(OfflineTileService.minBulkConcurrency),
      );
      expect(
        OfflineTileService(bulkConcurrency: 12).bulkConcurrency,
        equals(OfflineTileService.maxBulkConcurrency),
      );

      final fetched = await service.downloadRegion(
        centerLat: 35.6812,
        centerLon: 139.7671,
        radiusKm: 1.0,
        zoomLevels: const [14, 15],
      );

      expect(fetched, greaterThan(6));
      expect(peakActive, greaterThanOrEqualTo(2));
      expect(peakActive, lessThanOrEqualTo(3));
      // Polite 75 ms delay recorded between batches
      expect(recordedSleeps, isNotEmpty);
      expect(
        recordedSleeps.every((d) => d == OfflineTileService.defaultBulkBatchDelay),
        isTrue,
      );
    });

    test('caps offline zoom levels (<= 16) and tile counts (5,000-10,000 custom / 60 public)', () {
      // Zoom sanitization drops zooms > 16 and < 1
      expect(
        OfflineTileService.sanitizeOfflineZoomLevels(
          const [0, 13, 14, 15, 16, 17, 18, 19],
        ),
        equals(const [13, 14, 15, 16]),
      );

      final radiusTiles = OfflineTileService.tilesForRadius(
        centerLat: 35.6812,
        centerLon: 139.7671,
        radiusKm: 25.0,
        zoomLevels: const [14, 15, 16, 17, 18],
        maxTiles: 25000,
      );
      expect(radiusTiles.length, equals(OfflineTileService.hardMaxCustomBulkTiles));
      expect(
        radiusTiles.every((t) => t.z <= OfflineTileService.maxOfflineZoom),
        isTrue,
      );

      final defaultCapTiles = OfflineTileService.tilesForRadius(
        centerLat: 35.6812,
        centerLon: 139.7671,
        radiusKm: 25.0,
        zoomLevels: const [14, 15, 16],
        maxTiles: OfflineTileService.defaultCustomBulkTiles,
      );
      expect(defaultCapTiles.length, equals(OfflineTileService.defaultCustomBulkTiles));
    });

    test('HTTP 429 pauses queue for Retry-After duration and retries cleanly', () async {
      var now = DateTime.utc(2026, 11, 25, 6, 0, 0);
      final recordedPauses = <Duration>[];
      final seenPaths = <String, int>{};
      bool injected429 = false;

      final mockClient = MockClient((req) async {
        final key = req.url.path;
        final count = (seenPaths[key] ?? 0) + 1;
        seenPaths[key] = count;
        // Return HTTP 429 with Retry-After: 7 on the very first request
        if (!injected429) {
          injected429 = true;
          return http.Response(
            'Too Many Requests',
            429,
            headers: {'retry-after': '7'},
          );
        }
        return http.Response.bytes(
          _validPngBytes,
          200,
          headers: {'content-type': 'image/png'},
        );
      });

      final service = OfflineTileService(
        client: mockClient,
        diskCache: _InMemoryTileDiskCache(),
        customTileUrlTemplate: 'https://tiles.example.org/{z}/{x}/{y}.png',
        bulkConcurrency: 2,
        bulkThrottleDelay: Duration.zero,
        clock: () => now,
        sleep: (d) async {
          recordedPauses.add(d);
          now = now.add(d);
        },
      );

      final fetched = await service.downloadRegion(
        centerLat: 35.6812,
        centerLon: 139.7671,
        radiusKm: 0.6,
        zoomLevels: const [14, 15],
      );

      // Every tile in the region succeeded after pausing and retrying
      expect(fetched, equals(service.downloadTotal));
      expect(fetched, greaterThan(0));
      expect(recordedPauses, contains(const Duration(seconds: 7)));
      // Transient 429 warning clears once retry succeeds
      expect(service.lastDownloadWarning, isNull);
    });

    test('persistent HTTP 429 pauses up to retry budget then stops gracefully', () async {
      var now = DateTime.utc(2026, 11, 25, 6, 0, 0);
      final recordedPauses = <Duration>[];
      int requestCount = 0;

      final mockClient = MockClient((req) async {
        requestCount++;
        return http.Response(
          'Too Many Requests',
          429,
          headers: {'retry-after': '120'},
        );
      });

      final service = OfflineTileService(
        client: mockClient,
        diskCache: _InMemoryTileDiskCache(),
        customTileUrlTemplate: 'https://tiles.example.org/{z}/{x}/{y}.png',
        bulkConcurrency: 2,
        bulkThrottleDelay: Duration.zero,
        clock: () => now,
        sleep: (d) async {
          recordedPauses.add(d);
          now = now.add(d);
        },
      );

      final fetched = await service.downloadRegion(
        centerLat: 35.6812,
        centerLon: 139.7671,
        radiusKm: 1.5,
        zoomLevels: const [14, 15],
      );

      expect(fetched, equals(0));
      expect(
        recordedPauses.length,
        lessThanOrEqualTo(OfflineTileService.maxConsecutiveRateLimitPauses),
      );
      expect(
        recordedPauses.every((d) => d == const Duration(seconds: 120)),
        isTrue,
      );
      expect(requestCount, lessThanOrEqualTo(12));
      expect(service.lastDownloadWarning, isNotNull);

      // Retry-After parser handles seconds, RFC-1123 dates, and clamping
      final fixedNow = DateTime.utc(2026, 11, 25, 6, 0, 0);
      expect(
        OfflineTileService.parseRetryAfter('120', now: fixedNow),
        equals(const Duration(seconds: 120)),
      );
      expect(
        OfflineTileService.parseRetryAfter('5', now: fixedNow),
        equals(const Duration(seconds: 5)),
      );
      expect(
        OfflineTileService.parseRetryAfter('0', now: fixedNow),
        equals(const Duration(seconds: 1)),
      );
      expect(
        OfflineTileService.parseRetryAfter('9999', now: fixedNow),
        equals(const Duration(seconds: 300)),
      );
      expect(
        OfflineTileService.parseRetryAfter(
          'Wed, 25 Nov 2026 06:01:30 GMT',
          now: fixedNow,
        ),
        equals(const Duration(seconds: 90)),
      );
    });
  });

  group('OSMF Nominatim Usage Policy — User-Agent, Caching & Backoff', () {
    setUp(() {
      LocationContextService.resetNominatimStateForTest(
        minInterval: Duration.zero,
      );
    });

    tearDown(() {
      LocationContextService.resetNominatimStateForTest();
    });

    test('sends compliant User-Agent and caches repeated coordinate lookups', () async {
      int calls = 0;
      String? seenUserAgent;
      final mockClient = MockClient((req) async {
        calls++;
        seenUserAgent = req.headers['User-Agent'];
        return http.Response(
          jsonEncode({
            'name': 'Yoyogi Park',
            'category': 'leisure',
            'type': 'park',
            'address': {
              'park': 'Yoyogi Park',
              'city': 'Shibuya',
              'state': 'Tokyo',
              'country': 'Japan',
              'country_code': 'jp',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final first = await LocationContextService.resolveOverallPlaceOnline(
        35.6717,
        139.6949,
        client: mockClient,
      );
      final second = await LocationContextService.resolveOverallPlaceOnline(
        35.6717,
        139.6949,
        client: mockClient,
      );

      expect(first, isNotNull);
      expect(second, equals(first));
      expect(calls, equals(1)); // Cached on second call
      expect(seenUserAgent, equals(LocationContextService.userAgent));
      expect(seenUserAgent, startsWith('EdgeMapper/${AppEnvConfig.appVersion} ('));
      expect(seenUserAgent!.toLowerCase(), isNot(contains('openstreetmap.org')));

      final guess = await LocationContextService.guessFromCoordinatesOnline(
        35.6717,
        139.6949,
        client: mockClient,
      );
      final cachedGuess = await LocationContextService.guessFromCoordinatesOnline(
        35.6717,
        139.6949,
        client: mockClient,
      );
      expect(guess, isNotNull);
      expect(cachedGuess?.suggestedRouteName, equals(guess?.suggestedRouteName));
      expect(calls, equals(2)); // 1 overall + 1 guess (cached on repeat)
    });

    test('backs off cleanly after HTTP 429 from Nominatim', () async {
      int calls = 0;
      final mockClient = MockClient((req) async {
        calls++;
        return http.Response(
          'Too Many Requests',
          429,
          headers: {'retry-after': '60'},
        );
      });

      final first = await LocationContextService.resolveOverallPlaceOnline(
        48.8566,
        2.3522,
        client: mockClient,
      );
      final second = await LocationContextService.resolveOverallPlaceOnline(
        45.7640,
        4.8357,
        client: mockClient,
      );

      expect(first, isNull);
      expect(second, isNull);
      expect(calls, equals(1)); // Second call skipped during backoff
    });
  });
}
