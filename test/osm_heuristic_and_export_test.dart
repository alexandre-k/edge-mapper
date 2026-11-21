import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:edge_mapper/attest_gate_provider.dart';
import 'package:edge_mapper/data/osm_tag_catalog.dart';
import 'package:edge_mapper/data/osm_tag_standards.dart';
import 'package:edge_mapper/models/enrichment_diff.dart';
import 'package:edge_mapper/models/hike_trail.dart';
import 'package:edge_mapper/models/osm_record.dart';
import 'package:edge_mapper/services/connectivity_service.dart';
import 'package:edge_mapper/services/exif_gps_reader.dart';
import 'package:edge_mapper/services/e2ee_envelope_crypto.dart';
import 'package:edge_mapper/services/firebase_sync_service.dart';
import 'package:edge_mapper/services/gamification_service.dart';
import 'package:edge_mapper/services/gps_quality_service.dart';
import 'package:edge_mapper/services/hybrid_ai_service.dart';
import 'package:edge_mapper/services/location_context_service.dart';
import 'package:edge_mapper/services/offline_tile_service.dart';
import 'package:edge_mapper/services/osm_export_service.dart';
import 'package:edge_mapper/services/osm_heuristic_mapper.dart';
import 'package:edge_mapper/services/osm_publish_service.dart';
import 'package:edge_mapper/services/user_preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('GPS extrapolation & compass helpers', () {
    test('extrapolates North bearing by increasing latitude', () {
      final target = extrapolateCoordinate(
        latitude: 35.658581,
        longitude: 139.745433,
        bearingDegrees: 0.0,
        distanceMeters: 100.0,
      );
      expect(target.latitude, greaterThan(35.658581));
      expect((target.longitude - 139.745433).abs(), lessThan(1e-5));
    });

    test('extrapolates East bearing by increasing longitude', () {
      final target = extrapolateCoordinate(
        latitude: 35.658581,
        longitude: 139.745433,
        bearingDegrees: 90.0,
        distanceMeters: 100.0,
      );
      expect(target.longitude, greaterThan(139.745433));
      expect((target.latitude - 35.658581).abs(), lessThan(1e-5));
    });

    test('maps headings to 8-point cardinal directions', () {
      expect(cardinalDirection(0), 'N');
      expect(cardinalDirection(45), 'NE');
      expect(cardinalDirection(90), 'E');
      expect(cardinalDirection(180), 'S');
      expect(cardinalDirection(270), 'W');
      expect(cardinalDirection(350), 'N');
    });
  });

  group('Multilingual & dual-language offline OSM tag inference', () {
    test('detects bilingual Japanese + English shrine signage', () {
      final result = OsmHeuristicMapper.inferFromOnDeviceSignals(
        imageLabels: const ['Temple', 'Architecture', 'Tree'],
        ocrLines: const ['高尾山薬王院 神社', 'Takao Shrine'],
        headingDegrees: 42.4,
        isOnTrail: true,
        countryLanguage: 'ja',
        confidentLanguages: const ['en'],
        preferredFallbackLanguage: 'en',
      );

      expect(result.detectedLanguage, 'ja');
      expect(result.tags['name'], '高尾山薬王院 神社');
      expect(result.tags['name:ja'], '高尾山薬王院 神社');
      expect(result.tags['name:en'], 'Takao Shrine');
      expect(result.tags['amenity'], 'place_of_worship');
      expect(result.tags['religion'], 'shinto');
      // camera:direction is NOT a standard OSM tag for non-camera POIs
      expect(result.tags.containsKey('camera:direction'), isFalse);
      // source uses standard OSM survey (never GPS or the software name)
      expect(result.tags['source'], 'survey');

      // Directional OSM features (e.g. viewpoint) still keep standard `direction` tag
      final viewpoint = OsmHeuristicMapper.inferFromOnDeviceSignals(
        imageLabels: const ['Mountain', 'Panorama'],
        ocrLines: const [],
        headingDegrees: 42.4,
        hasGpsFix: false,
      );
      expect(viewpoint.tags['tourism'], 'viewpoint');
      expect(viewpoint.tags['direction'], '42');
      expect(viewpoint.tags.containsKey('camera:direction'), isFalse);
      expect(viewpoint.tags['source'], 'survey');
    });

    test('duplicates secondary tag in user preferred fallback language when not confident in local country language', () {
      final prefs = UserPreferencesService();
      prefs.setConfidentLanguages(const ['fr']);
      prefs.setPreferredFallbackLanguage('fr');

      expect(prefs.resolveUserLanguageForCountry('ja'), 'fr');

      final result = OsmHeuristicMapper.inferFromOnDeviceSignals(
        imageLabels: const ['Temple'],
        ocrLines: const ['高尾山神社', 'Takao Shrine'],
        countryLanguage: 'ja',
        confidentLanguages: const ['fr'],
        preferredFallbackLanguage: 'fr',
      );

      expect(result.tags['name:ja'], '高尾山神社');
      expect(result.tags['name:fr'], 'Takao Shrine');
    });

    test('detects French bakery signage as shop=bakery', () {
      final result = OsmHeuristicMapper.inferFromOnDeviceSignals(
        imageLabels: const ['Building', 'Food'],
        ocrLines: const ['Boulangerie du Soleil'],
        headingDegrees: 180.0,
        countryLanguage: 'fr',
      );

      expect(result.detectedLanguage, 'fr');
      expect(result.tags['name'], 'Boulangerie du Soleil');
      expect(result.tags['name:fr'], 'Boulangerie du Soleil');
      expect(result.tags['shop'], 'bakery');
    });
  });

  group('Improved visual distance estimation', () {
    test('estimates shorter distance for large close-up sign vs tiny distant storefront sign', () {
      final (closeMeters, closeReason) =
          OsmHeuristicMapper.estimateDistanceMeters(
        baseDistanceMeters: 8.0,
        maxOcrHeightRatio: 0.14,
        imageLabels: const ['Signage'],
      );
      final (farMeters, farReason) =
          OsmHeuristicMapper.estimateDistanceMeters(
        baseDistanceMeters: 8.0,
        maxOcrHeightRatio: 0.015,
        imageLabels: const ['Road', 'Building'],
      );

      expect(closeMeters, lessThan(6.0));
      expect(farMeters, greaterThan(15.0));
      expect(closeReason, isNotEmpty);
      expect(farReason, isNotEmpty);
    });
  });

  group('OSM Tag Catalog probability ranking & search', () {
    test('ranks matching picture tags highest and supports search', () {
      final cafeRecord = OsmRecord(
        id: 'cafe-1',
        createdAt: DateTime.utc(2026, 11, 21),
        latitude: 48.8566,
        longitude: 2.3522,
        summary: 'Corner coffee shop and terrace',
        tags: const {'amenity': 'cafe'},
        detectedLabels: const ['Coffee', 'Table', 'Building'],
        tagCandidates: const {'amenity=cafe': 0.95, 'outdoor_seating=yes': 0.86},
        aiSource: AiSource.mlKitOffline,
        status: RecordStatus.draftOffline,
      );

      final ranked = OsmTagCatalog.rankForRecord(cafeRecord);
      expect(ranked.first.entry.tagString, 'amenity=cafe');
      expect(
        ranked.take(6).any((r) => r.entry.tagString == 'outdoor_seating=yes'),
        isTrue,
      );

      final searched =
          OsmTagCatalog.rankForRecord(cafeRecord, query: 'wheelchair');
      expect(searched, isNotEmpty);
      expect(searched.every((r) => r.entry.key == 'wheelchair'), isTrue);
    });
  });

  group('Enrichment Diff (Merge vs Full Overwrite) & selective approval', () {
    test('computes added/modified/removed tags and applies only user-selected items', () {
      final before = OsmRecord(
        id: 'r1',
        createdAt: DateTime.utc(2026, 11, 21),
        latitude: 35.68,
        longitude: 139.76,
        estimatedOffsetMeters: 6.0,
        summary: 'Rough draft',
        notes: 'Old wrong note',
        tags: const {
          'building': 'yes',
          'fixme': 'Verify offline draft',
          'name': 'Old Name',
        },
        aiSource: AiSource.mlKitOffline,
        status: RecordStatus.draftOffline,
      );

      final proposed = before.copyWith(
        summary: 'Artisan Bakery',
        notes: 'Corner storefront with wooden entrance',
        estimatedOffsetMeters: 14.0,
        tags: const {
          'shop': 'bakery',
          'name': 'パン屋',
          'name:ja': 'パン屋',
          'name:en': 'Artisan Bakery',
        },
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.aiEnriched,
      );

      final diff = EnrichmentDiff.compute(
        before: before,
        proposed: proposed,
        mode: AiUpdateMode.overwriteAll,
      );

      expect(diff.summaryChanged, isTrue);
      expect(diff.notesChanged, isTrue);
      expect(diff.distanceChanged, isTrue);
      expect(diff.addedCount, 3); // shop, name:ja, name:en
      expect(diff.modifiedCount, 1); // name
      expect(diff.removedCount, 2); // building, fixme

      // User accepts summary, distance, shop, and removing fixme, but rejects notes & building removal
      final approved = diff.buildApprovedRecord(
        acceptSummary: true,
        acceptNotes: false,
        acceptDistance: true,
        acceptMetadata: true,
        acceptedTagKeys: const {'shop', 'fixme', 'name'},
      );

      expect(approved.summary, 'Artisan Bakery');
      expect(approved.notes, 'Old wrong note');
      expect(approved.estimatedOffsetMeters, 14.0);
      expect(approved.tags['shop'], 'bakery');
      expect(approved.tags['name'], 'パン屋');
      expect(approved.tags.containsKey('fixme'), isFalse);
      expect(approved.tags['building'], 'yes');
    });

    test('OsmRecord persists updatedAt and defaults legacy rows to createdAt', () {
      final created = DateTime.utc(2026, 11, 20, 8, 0);
      final updated = DateTime.utc(2026, 11, 22, 10, 30);

      final record = OsmRecord(
        id: 'rec-order-1',
        createdAt: created,
        updatedAt: updated,
        latitude: 35.68,
        longitude: 139.76,
        summary: 'Updated Cafe',
        tags: const {'amenity': 'cafe'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.aiEnriched,
      );

      final map = record.toDbMap();
      expect(map['updated_at'], updated.toIso8601String());

      final restored = OsmRecord.fromDbMap(map);
      expect(restored.createdAt, created);
      expect(restored.updatedAt, updated);

      // Legacy v2 row without updated_at falls back cleanly to created_at
      final legacyMap = Map<String, Object?>.from(map)..remove('updated_at');
      final legacyRestored = OsmRecord.fromDbMap(legacyMap);
      expect(legacyRestored.updatedAt, created);
    });
  });

  group('GPS Quality & Suspect Location Detection', () {
    test('flags Null Island, mocked GPS, poor accuracy, stale fix, and impossible jumps', () {
      final now = DateTime.utc(2026, 11, 21, 10, 0, 0);

      final nullIsland = GpsQualityService.evaluateRaw(
        latitude: 0.0,
        longitude: 0.0,
        accuracyMeters: 5.0,
        timestamp: now,
        now: now,
      );
      expect(nullIsland.level, GpsQualityLevel.suspect);

      final mocked = GpsQualityService.evaluateRaw(
        latitude: 35.68,
        longitude: 139.76,
        accuracyMeters: 5.0,
        timestamp: now,
        isMocked: true,
        now: now,
      );
      expect(mocked.level, GpsQualityLevel.suspect);

      final jump = GpsQualityService.evaluateRaw(
        latitude: 35.685,
        longitude: 139.76,
        accuracyMeters: 10.0,
        timestamp: now,
        now: now,
        previousLat: 35.680,
        previousLon: 139.76,
        previousTimestamp: now.subtract(const Duration(seconds: 2)),
      );
      expect(jump.level, GpsQualityLevel.suspect);
      expect(jump.jumpMeters, greaterThan(400));

      final poorAcc = GpsQualityService.evaluateRaw(
        latitude: 35.68,
        longitude: 139.76,
        accuracyMeters: 85.0,
        timestamp: now,
        now: now,
      );
      expect(poorAcc.level, GpsQualityLevel.suspect);

      final good = GpsQualityService.evaluateRaw(
        latitude: 35.68,
        longitude: 139.76,
        accuracyMeters: 7.5,
        timestamp: now,
        now: now,
      );
      expect(good.level, GpsQualityLevel.good);
      expect(good.level.shouldAdvertiseWarning, isFalse);
    });
  });

  group('Location auto-guessing, offline tile math, Firestore encoding & Gamification', () {
    test('parses Nominatim park response into parkStroll activity and country language', () {
      final guess = LocationContextService.parseNominatimResponse(
        {
          'category': 'leisure',
          'type': 'park',
          'name': 'Yoyogi Park',
          'address': {
            'leisure': 'Yoyogi Park',
            'suburb': 'Shibuya',
            'country_code': 'jp',
          },
        },
        35.6717,
        139.6949,
      );

      expect(guess.activityType, ActivityType.parkStroll);
      expect(guess.highway, 'footway');
      expect(guess.surface, 'compacted');
      expect(guess.countryLanguage, 'ja');
      expect(guess.suggestedRouteName, contains('Yoyogi Park'));
    });

    test('computes valid OSM Web Mercator tiles and offline radius set', () {
      final coord = OfflineTileService.latLonToTile(35.6812, 139.7671, 15);
      expect(coord.z, 15);
      expect(coord.x, greaterThan(28000));
      expect(coord.y, greaterThan(12000));

      final areaTiles = OfflineTileService.tilesForRadius(
        centerLat: 35.6812,
        centerLon: 139.7671,
        radiusKm: 1.0,
        zoomLevels: const [14, 15],
      );
      expect(areaTiles, isNotEmpty);
      expect(areaTiles.length, lessThanOrEqualTo(260));
    });

    test('encodes OsmRecord & HikeTrail to Firestore REST fields and computes Explorer XP/Badges', () async {
      final record = OsmRecord(
        id: 'rec-1',
        createdAt: DateTime.utc(2026, 11, 21, 8, 30),
        latitude: 35.6251,
        longitude: 139.2436,
        summary: 'Trailhead sign',
        detectedLanguage: 'ja',
        tags: const {
          'tourism': 'information',
          'information': 'guidepost',
          'name': '高尾山登山口',
          'name:ja': '高尾山登山口',
          'name:en': 'Mt. Takao Trailhead',
        },
        aiSource: AiSource.mlKitOffline,
        status: RecordStatus.aiEnriched,
        firebaseSyncedAt: DateTime.utc(2026, 11, 21, 9, 0),
      );

      final trail = HikeTrail(
        id: 'trail-1',
        name: 'Yoyogi Park Walk',
        startedAt: DateTime.utc(2026, 11, 21, 8, 0),
        endedAt: DateTime.utc(2026, 11, 21, 9, 0),
        isActive: false,
        activityType: ActivityType.parkStroll,
        tags: const {'highway': 'footway', 'surface': 'compacted'},
        points: [
          TrailPoint(
            trailId: 'trail-1',
            latitude: 35.6710,
            longitude: 139.6940,
            altitudeMeters: 30,
            recordedAt: DateTime.utc(2026, 11, 21, 8, 0),
          ),
          TrailPoint(
            trailId: 'trail-1',
            latitude: 35.6810,
            longitude: 139.6940,
            altitudeMeters: 35,
            recordedAt: DateTime.utc(2026, 11, 21, 8, 20),
          ),
        ],
      );

      final fsRecord = FirebaseSyncService.encodeRecordToFirestoreFields(
        record,
        photoDataUri: 'data:image/jpeg;base64,AAAA',
      );
      expect(fsRecord['id']['stringValue'], 'rec-1');
      expect(
        fsRecord['tags']['mapValue']['fields']['name:ja']['stringValue'],
        '高尾山登山口',
      );
      final decodedRecord =
          FirebaseSyncService.decodeRecordFromFirestoreFields(fsRecord);
      expect(decodedRecord, isNotNull);
      expect(decodedRecord!.record.id, 'rec-1');
      expect(decodedRecord.record.tags['name:ja'], '高尾山登山口');
      expect(decodedRecord.record.tags['name:en'], 'Mt. Takao Trailhead');
      expect(decodedRecord.photoDataUri, 'data:image/jpeg;base64,AAAA');

      final fsTrail = FirebaseSyncService.encodeTrailToFirestoreFields(trail);
      expect(fsTrail['activityType']['stringValue'], 'parkStroll');
      expect((fsTrail['points']['arrayValue']['values'] as List).length, 2);
      final decodedTrail =
          FirebaseSyncService.decodeTrailFromFirestoreFields(fsTrail);
      expect(decodedTrail, isNotNull);
      expect(decodedTrail!.id, 'trail-1');
      expect(decodedTrail.name, 'Yoyogi Park Walk');
      expect(decodedTrail.points.length, 2);

      // Verify FirebaseSyncService requires a signed-in non-anonymous user + unlocked
      // X25519 E2EE keyring, stores items under /items/{itemId} encrypted with
      // XChaCha20-Poly1305 + document-path AAD (zero plaintext in Firestore),
      // preserves encrypted remote photos on metadata-only edits, decrypts cleanly
      // on pull, and supports full cloud wipe (`deleteAllCloudData`)!
      final seenRequests = <http.Request>[];
      final seenBodies = <Map<String, dynamic>>[];
      final fakeFirestoreDocs = <String, Map<String, dynamic>>{};
      final mockFsClient = MockClient((req) async {
        seenRequests.add(req);
        if (req.method == 'POST' && req.url.path.endsWith(':runQuery')) {
          final parsed = jsonDecode(req.body) as Map<String, dynamic>;
          final sq = parsed['structuredQuery'] as Map<String, dynamic>;
          final targetUid =
              sq['where']['fieldFilter']['value']['stringValue'].toString();
          final rows = <Map<String, dynamic>>[];
          fakeFirestoreDocs.forEach((p, doc) {
            if (!p.contains('/documents/items/')) return;
            final fields = doc['fields'] as Map<String, dynamic>;
            final vals =
                (fields['recipient_uids']?['arrayValue']?['values'] as List?) ??
                    const [];
            if (vals.any((v) => v['stringValue'] == targetUid)) {
              rows.add({'document': doc});
            }
          });
          return http.Response(jsonEncode(rows), 200);
        }
        if (req.method == 'PATCH' && req.body.isNotEmpty) {
          final parsed = jsonDecode(req.body) as Map<String, dynamic>;
          seenBodies.add(parsed);
          final existing = fakeFirestoreDocs[req.url.path];
          final mask = req.url.queryParametersAll['updateMask.fieldPaths'];
          if (existing != null && mask != null && mask.isNotEmpty) {
            final mergedFields = Map<String, dynamic>.from(
              existing['fields'] as Map<String, dynamic>,
            );
            final newFields = parsed['fields'] as Map<String, dynamic>;
            for (final path in mask) {
              if (newFields.containsKey(path)) {
                mergedFields[path] = newFields[path];
              }
            }
            fakeFirestoreDocs[req.url.path] = {
              'name': req.url.path,
              'fields': mergedFields,
            };
          } else {
            fakeFirestoreDocs[req.url.path] = {
              'name': req.url.path,
              'fields': parsed['fields'],
            };
          }
          return http.Response('{}', 200);
        }
        if (req.method == 'GET') {
          final doc = fakeFirestoreDocs[req.url.path];
          if (doc == null) return http.Response('{}', 404);
          return http.Response(jsonEncode(doc), 200);
        }
        if (req.method == 'DELETE') {
          fakeFirestoreDocs.remove(req.url.path);
          return http.Response('{}', 200);
        }
        return http.Response('{}', 200);
      });
      final syncPrefs = UserPreferencesService();

      // Unauthenticated calls must be blocked before hitting Firestore
      final unauthFsService = FirebaseSyncService(
        prefs: syncPrefs,
        client: mockFsClient,
        projectIdOverride: () => 'test-edge-mapper',
      );
      expect(unauthFsService.isSignedIn, isFalse);
      expect(
        () => unauthFsService.syncRecord(record),
        throwsA(isA<FirebaseAuthRequiredException>()),
      );
      expect(
        () => unauthFsService.syncTrail(trail),
        throwsA(isA<FirebaseAuthRequiredException>()),
      );
      expect(
        () => unauthFsService.fetchAllRecords(),
        throwsA(isA<FirebaseAuthRequiredException>()),
      );
      expect(seenRequests, isEmpty);

      // Signed in WITHOUT unlocked E2EE X25519 keyring must ALSO refuse to upload plaintext!
      const testUid = 'uid-alice-123';
      final lockedFsService = FirebaseSyncService(
        prefs: syncPrefs,
        client: mockFsClient,
        uidOverride: () => testUid,
        projectIdOverride: () => 'test-edge-mapper',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-alice',
      );
      expect(lockedFsService.isSignedIn, isTrue);
      expect(lockedFsService.canSyncNow, isFalse);
      expect(
        () => lockedFsService.syncRecord(record),
        throwsA(isA<FirebaseAuthRequiredException>()),
      );

      // Authenticated + Unlocked X25519 keyring -> XChaCha20-Poly1305 envelope sync
      final fsService = FirebaseSyncService(
        prefs: syncPrefs,
        client: mockFsClient,
        uidOverride: () => testUid,
        projectIdOverride: () => 'test-edge-mapper',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-alice',
      );
      fsService.setUnlockedKeyPairForTest(X25519.generateKeyPair());
      expect(fsService.isSignedIn, isTrue);
      expect(fsService.canSyncNow, isTrue);

      final uploadedWithPhoto = await fsService.syncRecord(
        record,
        photoDataUriOverride: 'data:image/jpeg;base64,AAAA',
      );
      expect(uploadedWithPhoto, isTrue);
      expect(
        seenRequests.last.url.path,
        '/v1/projects/test-edge-mapper/databases/(default)/documents/items/rec_rec-1',
      );
      expect(seenRequests.last.headers['Authorization'], 'Bearer jwt-alice');
      expect(
        seenRequests.last.url.queryParametersAll['updateMask.fieldPaths'],
        isNull,
      );
      final rawUploadedRecordJson = jsonEncode(seenBodies.last);
      expect(seenBodies.last['fields']['owner_uid']['stringValue'], testUid);
      expect(seenBodies.last['fields']['schema_version']['integerValue'], '1');
      expect(seenBodies.last['fields']['nonce']['stringValue'], isNotEmpty);
      expect(seenBodies.last['fields']['ciphertext']['stringValue'], isNotEmpty);
      expect(seenBodies.last['fields']['photo_nonce']['stringValue'], isNotEmpty);
      expect(
        seenBodies.last['fields']['photo_ciphertext']['stringValue'],
        isNotEmpty,
      );
      // ZERO plaintext user data or photo leaked into Firestore!
      expect(rawUploadedRecordJson, isNot(contains('高尾山登山口')));
      expect(rawUploadedRecordJson, isNot(contains('Mt. Takao Trailhead')));
      expect(
        rawUploadedRecordJson,
        isNot(contains('data:image/jpeg;base64,AAAA')),
      );

      // Metadata-only update uses updateMask excluding photo_nonce/photo_ciphertext
      final uploadedWithoutPhoto = await fsService.syncRecord(record);
      expect(uploadedWithoutPhoto, isFalse);
      final maskPaths =
          seenRequests.last.url.queryParametersAll['updateMask.fieldPaths'] ??
              const [];
      expect(maskPaths, containsAll(['owner_uid', 'nonce', 'ciphertext']));
      expect(maskPaths, isNot(contains('photo_nonce')));
      expect(maskPaths, isNot(contains('photo_ciphertext')));

      // E2EE trail upload -> ZERO plaintext trail name or GPS coordinates in Firestore!
      await fsService.syncTrail(trail);
      expect(
        seenRequests.last.url.path,
        '/v1/projects/test-edge-mapper/databases/(default)/documents/items/trail_trail-1',
      );
      final rawUploadedTrailJson = jsonEncode(seenBodies.last);
      expect(seenBodies.last['fields']['owner_uid']['stringValue'], testUid);
      expect(seenBodies.last['fields']['schema_version']['integerValue'], '1');
      expect(rawUploadedTrailJson, isNot(contains('Yoyogi Park Walk')));

      // Pull decrypts BOTH metadata AND preserved encrypted photo + trail!
      final pulledRecords = await fsService.fetchAllRecords();
      expect(pulledRecords.length, 1);
      expect(pulledRecords.first.record.id, 'rec-1');
      expect(pulledRecords.first.record.tags['name:ja'], '高尾山登山口');
      expect(pulledRecords.first.record.tags['name:en'], 'Mt. Takao Trailhead');
      expect(pulledRecords.first.photoDataUri, 'data:image/jpeg;base64,AAAA');

      final pulledTrails = await fsService.fetchAllTrails();
      expect(pulledTrails.length, 1);
      expect(pulledTrails.first.id, 'trail-1');
      expect(pulledTrails.first.name, 'Yoyogi Park Walk');
      expect(pulledTrails.first.points.length, 2);

      // Delete ALL Firestore data on demand while keeping local copies intact
      final wipeResult = await fsService.deleteAllCloudData();
      expect(wipeResult.hasErrors, isFalse);
      expect(wipeResult.recordsDeleted, 1);
      expect(wipeResult.trailsDeleted, 1);
      expect(fakeFirestoreDocs, isEmpty);

      final profile = GamificationService.computeProfile(
        records: [record],
        trails: [trail],
      );
      expect(profile.xp, greaterThan(100));
      expect(profile.level, greaterThanOrEqualTo(2));
      expect(
        profile.badges.where((b) => b.unlocked).map((b) => b.id),
        containsAll(['first_pin', 'polyglot', 'trailblazer', 'park_wanderer', 'cloud_archivist']),
      );
    });
  });

  group('OSM XML / GPX / GeoJSON export', () {
    final sampleRecord = OsmRecord(
      id: 'rec-1',
      createdAt: DateTime.utc(2026, 11, 21, 8, 30),
      latitude: 35.6251,
      longitude: 139.2436,
      headingDegrees: 120,
      extrapolatedLatitude: 35.62505,
      extrapolatedLongitude: 139.24368,
      estimatedOffsetMeters: 8,
      summary: 'Trailhead sign',
      detectedLanguage: 'ja',
      tags: const {
        'tourism': 'information',
        'information': 'guidepost',
        'name': '高尾山登山口',
        'name:ja': '高尾山登山口',
        'name:en': 'Mt. Takao Trailhead',
      },
      aiSource: AiSource.mlKitOffline,
      status: RecordStatus.draftOffline,
    );

    final sampleTrail = HikeTrail(
      id: 'trail-1',
      name: 'Takao Ridge',
      startedAt: DateTime.utc(2026, 11, 21, 8, 0),
      endedAt: DateTime.utc(2026, 11, 21, 9, 0),
      isActive: false,
      tags: const {'highway': 'path', 'surface': 'ground'},
      points: [
        TrailPoint(
          trailId: 'trail-1',
          latitude: 35.6251,
          longitude: 139.2436,
          altitudeMeters: 210,
          recordedAt: DateTime.utc(2026, 11, 21, 8, 0),
        ),
        TrailPoint(
          trailId: 'trail-1',
          latitude: 35.6260,
          longitude: 139.2440,
          altitudeMeters: 250,
          recordedAt: DateTime.utc(2026, 11, 21, 8, 15),
        ),
      ],
    );

    test('builds valid OSM XML containing node and trail way', () {
      final xml = OsmExportService.buildOsmXml(
        records: [sampleRecord],
        trails: [sampleTrail],
      );
      expect(xml, contains('<osm version="0.6"'));
      expect(xml, contains('k="name:ja" v="高尾山登山口"'));
      expect(xml, contains('k="name:en" v="Mt. Takao Trailhead"'));
      expect(xml, contains('<way id="-1"'));
      expect(xml, contains('k="highway" v="path"'));
    });

    test('builds valid GPX containing waypoint and track', () {
      final gpx = OsmExportService.buildGpx(
        records: [sampleRecord],
        trails: [sampleTrail],
      );
      expect(gpx, contains('<gpx version="1.1"'));
      expect(gpx, contains('<wpt '));
      expect(gpx, contains('<trkpt '));
    });

    test('builds valid GeoJSON FeatureCollection', () {
      final geo = OsmExportService.buildGeoJson(
        records: [sampleRecord],
        trails: [sampleTrail],
      );
      final parsed = jsonDecode(geo) as Map<String, dynamic>;
      expect(parsed['type'], 'FeatureCollection');
      expect((parsed['features'] as List).length, 2);
    });
  });

  group('Cloud AI transient retry, high-demand classification & model fallback', () {
    const firebaseHighDemand500 = '''
FirebaseAIException: Server Error [500]: {
  "error": {
    "code": 500,
    "message": "This model is currently experiencing high demand. Spikes in demand are usually temporary. Please try again later.",
    "status": "INTERNAL"
  }
}''';

    test('classifies 500 high demand, 503, 429, and timeouts as transient errors', () {
      expect(
        HybridAiService.isTransientCloudError(Exception(firebaseHighDemand500)),
        isTrue,
      );
      expect(
        HybridAiService.isTransientCloudError(
          Exception('Gemini API error (429): RESOURCE_EXHAUSTED'),
        ),
        isTrue,
      );
      expect(
        HybridAiService.isTransientCloudError(
          TimeoutException('Request timed out'),
        ),
        isTrue,
      );
      expect(
        HybridAiService.isTransientCloudError(
          Exception('FirebaseAIException: [403] PERMISSION_DENIED'),
        ),
        isFalse,
      );
      expect(
        HybridAiService.isAuthOrConfigError(
          Exception('FirebaseAIException: [403] PERMISSION_DENIED'),
        ),
        isTrue,
      );
      expect(
        HybridAiService.isModelUnavailableError(
          Exception('models/gemini-2.0-flash is no longer available'),
        ),
        isTrue,
      );
      expect(
        HybridAiService.isModelUnavailableError(
          Exception(
            'To access this model, you must enforce Firebase App Check. Learn more: https://firebase.google.com/docs/ai-logic/app-check',
          ),
        ),
        isTrue,
      );
      expect(
        HybridAiService.formatCloudError(
          Exception(
            'To access this model, you must enforce Firebase App Check. Learn more: https://firebase.google.com/docs/ai-logic/app-check',
          ),
        ),
        contains('App Check'),
      );
      final invalidTokenErr = Exception('Firebase App Check token is invalid.');
      expect(HybridAiService.isAppCheckTokenError(invalidTokenErr), isTrue);
      expect(HybridAiService.isAuthOrConfigError(invalidTokenErr), isTrue);
      expect(HybridAiService.isModelUnavailableError(invalidTokenErr), isFalse);
      final formattedInvalidToken =
          HybridAiService.formatCloudError(invalidTokenErr);
      expect(formattedInvalidToken, contains('App Check token rejected'));
      expect(formattedInvalidToken, isNot(contains('Switch to a Flash/Lite')));

      final attestGateErr = Exception(
        'Firebase App Check token is invalid. — AttestGate token refresh failed: attest-gate returned HTTP 403: cert mismatch',
      );
      expect(HybridAiService.isAppCheckTokenError(attestGateErr), isTrue);
      expect(
        HybridAiService.formatCloudError(attestGateErr),
        contains('HTTP 403: cert mismatch'),
      );
    });

    test('AttestGateAppCheck.inspectJwtPayload safely decodes non-secret claims', () {
      final header = base64Url.encode(utf8.encode('{"alg":"RS256"}')).replaceAll('=', '');
      final payload = base64Url
          .encode(utf8.encode('{"sub":"1:000000000000:android:0123456789abcdef012345","exp":1800000000}'))
          .replaceAll('=', '');
      final claims = AttestGateAppCheck.inspectJwtPayload('$header.$payload.sig');
      expect(claims, isNotNull);
      expect(claims!['sub'], '1:000000000000:android:0123456789abcdef012345');
      expect(claims['exp'], 1800000000);
      expect(AttestGateAppCheck.inspectJwtPayload('not-a-jwt'), isNull);
    });

    test('formats verbose high-demand JSON error into a concise actionable message', () {
      final formatted =
          HybridAiService.formatCloudError(Exception(firebaseHighDemand500));
      expect(formatted, contains('high demand'));
      expect(formatted, isNot(contains('"status": "INTERNAL"')));
    });

    test('defaults to valid 3.5-flash-lite and skips invalid 3.8-pro / 3.8-flash-lite models', () {
      expect(UserPreferencesService.defaultModelId, 'gemini-3.5-flash-lite');

      final liteOrder = HybridAiService.buildFallbackModelOrder(
        'gemini-3.5-flash-lite',
        UserPreferencesService.defaultGeminiModels,
        maxCandidates: 4,
      );
      expect(liteOrder[0], 'gemini-3.5-flash-lite');
      expect(liteOrder[1], 'gemini-3.8-flash');
      expect(liteOrder[2], 'gemini-4-hydrogen');
      expect(liteOrder, isNot(contains('gemini-2.5-flash')));
      expect(liteOrder, isNot(contains('gemini-3.8-pro')));
      expect(liteOrder, isNot(contains('gemini-3.8-flash-lite')));

      // Legacy invalid selection like gemini-3.8-pro is skipped cleanly
      final migratedOrder = HybridAiService.buildFallbackModelOrder(
        'gemini-3.8-pro',
        const ['gemini-3.8-flash-lite', 'gemini-3.8-pro', 'gemini-3.8-flash'],
        maxCandidates: 4,
      );
      expect(migratedOrder, isNot(contains('gemini-3.8-pro')));
      expect(migratedOrder, isNot(contains('gemini-3.8-flash-lite')));
      expect(migratedOrder.first, 'gemini-3.5-flash-lite');

      final withCooldown = HybridAiService.buildFallbackModelOrder(
        'gemini-3.8-flash',
        UserPreferencesService.defaultGeminiModels,
        cooledDownModels: const {'gemini-3.8-flash'},
        maxCandidates: 4,
      );
      expect(withCooldown[0], 'gemini-3.5-flash-lite');
      expect(withCooldown[1], 'gemini-4-hydrogen');
      expect(withCooldown.first, isNot('gemini-3.8-flash'));
    });

    test('enables Nano 4 record enrichment even when offline or in local-first mode', () async {
      final connectivity = ConnectivityService();
      connectivity.setForceOffline(true);
      final prefs = UserPreferencesService();
      await prefs.setAiProviderMode(AiProviderMode.localFirst);

      final aiWithNano = HybridAiService(
        connectivity: connectivity,
        prefs: prefs,
        initialNanoStatus: const GeminiNanoStatus(
          available: true,
          aicoreInstalled: true,
          deviceModel: 'Desktop Web (Gemini Nano 4)',
          sdkInt: 0,
          reason: 'Ready',
        ),
      );
      expect(aiWithNano.canUseAnyCloudAi, isFalse);
      expect(aiWithNano.canUseLocalNano, isTrue);
      expect(aiWithNano.canEnrichRecords, isTrue);
      expect(aiWithNano.willEnrichUseNanoFirst, isTrue);

      final aiWithoutNano = HybridAiService(
        connectivity: connectivity,
        prefs: prefs,
      );
      expect(aiWithoutNano.canEnrichRecords, isFalse);
    });

    test('retries transient errors with backoff and succeeds on later attempt', () async {
      int attempts = 0;
      final recordedDelays = <Duration>[];
      final res = await HybridAiService.runWithTransientRetry<String>(
        maxAttempts: 3,
        initialDelay: const Duration(milliseconds: 100),
        sleeper: (d) async => recordedDelays.add(d),
        action: (attempt) async {
          attempts = attempt;
          if (attempt < 3) {
            throw Exception(firebaseHighDemand500);
          }
          return 'ok';
        },
      );

      expect(res, 'ok');
      expect(attempts, 3);
      expect(recordedDelays.length, 2);
      expect(recordedDelays[1].inMilliseconds, greaterThanOrEqualTo(200));
    });

    test('does not retry non-transient errors and respects cancellation', () async {
      int nonTransientAttempts = 0;
      await expectLater(
        HybridAiService.runWithTransientRetry<String>(
          maxAttempts: 3,
          sleeper: (_) async {},
          action: (attempt) async {
            nonTransientAttempts = attempt;
            throw Exception('PERMISSION_DENIED [403]');
          },
        ),
        throwsException,
      );
      expect(nonTransientAttempts, 1);

      const freeTierQuotaErr = '''
You exceeded your current quota, please check your plan and billing details. For more information on this error, head to: https://aistudio.google.com/docs/rate-limits.
* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 20, model: gemini-3.8-flash, description: Generate content requests per day limit exceeded on Free Tier.
Please retry in 6h10m55.756153536s.''';

      expect(
        HybridAiService.isQuotaExceededError(Exception(freeTierQuotaErr)),
        isTrue,
      );
      expect(
        HybridAiService.isTransientCloudError(Exception(freeTierQuotaErr)),
        isTrue,
      );
      expect(
        HybridAiService.formatCloudError(Exception(freeTierQuotaErr)),
        contains('quota'),
      );

      // Quota errors must NOT waste retries on the same exhausted model
      int quotaAttempts = 0;
      await expectLater(
        HybridAiService.runWithTransientRetry<String>(
          maxAttempts: 3,
          sleeper: (_) async {},
          action: (attempt) async {
            quotaAttempts = attempt;
            throw Exception(freeTierQuotaErr);
          },
        ),
        throwsException,
      );
      expect(quotaAttempts, 1);

      bool cancelled = false;
      await expectLater(
        HybridAiService.runWithTransientRetry<String>(
          maxAttempts: 3,
          shouldCancel: () => cancelled,
          sleeper: (_) async => cancelled = true,
          action: (_) async => throw Exception(firebaseHighDemand500),
        ),
        throwsA(isA<AiBatchCancelledException>()),
      );
    });

    test('prioritizes Personal Gemini API key in Auto/LocalFirst, auto-discovers live models on 503/404, and tests generateContent', () async {
      final connectivity = ConnectivityService(initialHasNetwork: true);
      final prefs = UserPreferencesService();
      await prefs.setAiProviderMode(AiProviderMode.localFirst);
      await prefs.setPersonalGeminiApiKey('AIza-test-personal-key');

      final requestedModels = <String>[];
      final mockClient = MockClient((req) async {
        if (req.method == 'GET' && req.url.path.endsWith('/v1beta/models')) {
          return http.Response(
            jsonEncode({
              'models': [
                {
                  'name': 'models/gemini-2.5-flash-lite',
                  'supportedGenerationMethods': ['generateContent'],
                },
                {
                  'name': 'models/gemini-2.5-flash',
                  'supportedGenerationMethods': ['generateContent'],
                },
                {
                  'name': 'models/gemini-embedding-001',
                  'supportedGenerationMethods': ['embedContent'],
                },
                {
                  'name': 'models/gemini-2.5-flash-preview-tts',
                  'supportedGenerationMethods': ['generateContent'],
                },
              ],
            }),
            200,
          );
        }
        if (req.method == 'POST' && req.url.path.contains(':generateContent')) {
          final modelName = req.url.path
              .split('/models/')
              .last
              .split(':generateContent')
              .first;
          requestedModels.add(modelName);
          // Simulate default 3.x models returning 503 high demand / 404
          if (modelName.startsWith('gemini-3.') ||
              modelName.startsWith('gemini-4')) {
            return http.Response(
              '{"error":{"code":503,"message":"This model is currently experiencing high demand.","status":"UNAVAILABLE"}}',
              503,
            );
          }
          // Live discovered gemini-2.5-flash-lite succeeds!
          if (modelName == 'gemini-2.5-flash-lite') {
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'OK'},
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }
        }
        return http.Response('Not found', 404);
      });

      final ai = HybridAiService(
        connectivity: connectivity,
        prefs: prefs,
        httpClient: mockClient,
      );

      // Personal Gemini API key is prioritized in Local First & Auto modes
      expect(ai.activeCloudProvider, equals(AiProviderMode.personalGeminiApi));
      expect(ai.activeEngineLabel, contains('Gemini API'));

      // testActiveCloudAi discovers live models, skips busy 503 models, and switches to working model
      await prefs.setAiProviderMode(AiProviderMode.personalGeminiApi);
      final testMsg = await ai.testActiveCloudAi();
      expect(testMsg, contains('Personal Gemini API (gemini-2.5-flash-lite): OK'));
      expect(prefs.selectedGeminiModel, equals('gemini-2.5-flash-lite'));
      expect(prefs.availableGeminiModels, contains('gemini-2.5-flash-lite'));
      expect(prefs.availableGeminiModels, contains('gemini-2.5-flash'));
      expect(prefs.availableGeminiModels, isNot(contains('gemini-embedding-001')));
      expect(
        prefs.availableGeminiModels,
        isNot(contains('gemini-2.5-flash-preview-tts')),
      );
      expect(requestedModels, contains('gemini-2.5-flash-lite'));

      // Invalid key error formats cleanly
      expect(
        HybridAiService.formatCloudError(
          Exception('Personal Gemini API error (400): {"error":{"status":"INVALID_ARGUMENT","message":"API key not valid."}}'),
        ),
        contains('API key is invalid'),
      );
    });
  });

  group('OpenStreetMap OAuth 2.0 PKCE & API v0.6 Publishing', () {
    test('generates PKCE S256 pair and extracts authorization codes from URLs or raw input', () {
      final pkce = OsmPublishService.generatePkcePair();
      expect(pkce.verifier.length, greaterThanOrEqualTo(43));
      expect(pkce.challenge.length, 43);
      expect(pkce.verifier, isNot(contains('=')));
      expect(pkce.challenge, isNot(contains('=')));
      expect(pkce.state, isNotEmpty);

      expect(
        OsmPublishService.extractAuthCode(
          'http://127.0.0.1:8080/osm_callback.html?code=abc_123&state=xyz',
        ),
        'abc_123',
      );
      expect(OsmPublishService.extractAuthCode('  raw_code_99  '), 'raw_code_99');
    });

    test('validates records, builds valid OsmChange XML, and parses diffResult IDs', () {
      final badRecord = OsmRecord(
        id: 'bad-1',
        createdAt: DateTime.utc(2026, 11, 22),
        latitude: 0.0,
        longitude: 0.0,
        summary: 'Null Island',
        tags: const {'source': 'Edge Mapper'},
        aiSource: AiSource.manual,
        status: RecordStatus.draftOffline,
      );
      final badIssues = OsmPublishService.validateForPublish(records: [badRecord]);
      expect(badIssues.where((i) => i.isBlocking).length, 2);

      final goodRecord = OsmRecord(
        id: 'good-1',
        createdAt: DateTime.utc(2026, 11, 22),
        latitude: 35.6812,
        longitude: 139.7671,
        summary: 'Coffee & Bakery',
        tags: const {'amenity': 'cafe', 'name': 'Sun & Bean'},
        notes: 'Corner terrace',
        aiSource: AiSource.geminiNano,
        status: RecordStatus.readyToUpload,
      );
      final goodIssues = OsmPublishService.validateForPublish(records: [goodRecord]);
      expect(goodIssues.where((i) => i.isBlocking), isEmpty);

      final osc = OsmPublishService.buildOsmChangeXml(
        changesetId: 424242,
        records: [goodRecord],
      );
      expect(osc, contains('<osmChange version="0.6"'));
      expect(osc, contains('changeset="424242"'));
      expect(osc, contains('v="Sun &amp; Bean"'));
      // Legacy record.notes is not auto-exported as an OSM `note` tag unless explicitly added to tags
      expect(osc, isNot(contains('k="note" v="Corner terrace"')));

      const diffXml = '''
<diffResult generator="OpenStreetMap Server" version="0.6">
  <node old_id="-1" new_id="99887766" new_version="1"/>
  <way old_id="-1" new_id="55443322" new_version="1"/>
</diffResult>''';
      final parsed = OsmPublishService.parseDiffResult(diffXml);
      expect(parsed.createdNodeIds[-1], 99887766);
      expect(parsed.createdWayIds[-1], 55443322);
    });

    test('publishes changeset via create -> upload -> close with OAuth 2.0 Bearer auth', () async {
      final calls = <String>[];
      final mockClient = MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        expect(req.headers['Authorization'], 'Bearer test-osm-token');

        if (req.method == 'PUT' && req.url.path == '/api/0.6/changeset/create') {
          expect(req.body, contains('k="comment" v="Test survey"'));
          return http.Response('123456', 200);
        }
        if (req.method == 'POST' && req.url.path == '/api/0.6/changeset/123456/upload') {
          expect(req.body, contains('changeset="123456"'));
          return http.Response(
            '<diffResult version="0.6"><node old_id="-1" new_id="777001" new_version="1"/></diffResult>',
            200,
          );
        }
        if (req.method == 'PUT' && req.url.path == '/api/0.6/changeset/123456/close') {
          return http.Response('', 200);
        }
        return http.Response('Unexpected ${req.method} ${req.url}', 400);
      });

      final prefs = UserPreferencesService();
      await prefs.setOsmUseSandbox(true);
      await prefs.setOsmAuthSession(
        accessToken: 'test-osm-token',
        username: 'AlexMapper',
        userId: 42,
      );

      final service = OsmPublishService(prefs: prefs, client: mockClient);
      final rec = OsmRecord(
        id: 'pub-1',
        createdAt: DateTime.utc(2026, 11, 22),
        latitude: 48.8566,
        longitude: 2.3522,
        summary: 'Public Bench',
        tags: const {'amenity': 'bench'},
        aiSource: AiSource.geminiNano,
        status: RecordStatus.readyToUpload,
      );

      final result = await service.publishChangeset(
        records: [rec],
        changesetComment: 'Test survey',
      );

      expect(calls, [
        'PUT /api/0.6/changeset/create',
        'POST /api/0.6/changeset/123456/upload',
        'PUT /api/0.6/changeset/123456/close',
      ]);
      expect(result.changesetId, 123456);
      expect(result.isSandbox, isTrue);
      expect(
        result.changesetUrl,
        'https://master.apis.dev.openstreetmap.org/changeset/123456',
      );
      expect(result.createdNodeIds, [777001]);
    });
  });

  group('OSM Tag Standards, Deprecation Guard, Non-Published Tags & Survey Source', () {
    test('automatically folds deprecated day_off into opening_hours with days before hours', () {
      // Bare hours + day_off=Wednesday -> Mo,Tu,Th-Su 09:00-18:00
      final wedOff = OsmTagStandards.modernizeTags({
        'shop': 'bakery',
        'opening_hours': '9:00-18:00',
        'day_off': 'Wednesday',
      });
      expect(wedOff.containsKey('day_off'), isFalse);
      expect(wedOff['opening_hours'], 'Mo,Tu,Th-Su 09:00-18:00');

      // Mo-Su hours + day_off=Monday -> Tu-Su 09:30-18:00
      final monOff = OsmTagStandards.modernizeTags({
        'shop': 'farm',
        'opening_hours': 'Mo-Su 09:30-18:00',
        'day_off': 'Monday',
      });
      expect(monOff.containsKey('day_off'), isFalse);
      expect(monOff['opening_hours'], 'Tu-Su 09:30-18:00');

      // Japanese day_off + public holiday
      final jpOff = OsmTagStandards.modernizeTags({
        'amenity': 'cafe',
        'opening_hours': '10:00～19:00',
        'day_off': '水曜・祝',
      });
      expect(jpOff.containsKey('day_off'), isFalse);
      expect(jpOff['opening_hours'], 'Mo,Tu,Th-Su 10:00-19:00; PH off');

      // Only day_off with no hours -> We off
      final onlyOff = OsmTagStandards.modernizeTags({
        'amenity': 'restaurant',
        'day_off': 'Wed',
      });
      expect(onlyOff.containsKey('day_off'), isFalse);
      expect(onlyOff['opening_hours'], 'We off');

      // Non-standard weekday names normalized to OSM 2-letter codes
      expect(
        OsmTagStandards.normalizeOpeningHours('Mon-Fri 9:00 to 18:00; Sun closed'),
        'Mo-Fr 09:00-18:00; Su off',
      );
    });

    test('modernizes other deprecated OSM tags and builds valid OSM Wiki URLs', () {
      final modernized = OsmTagStandards.modernizeTags({
        'amenity': 'gym',
        'wifi': 'free',
        'phone_number': '+81-3-0000-0000',
        'surface': 'cobblestone',
        'wheelchair': 'true',
        'created_by': 'Edge Mapper',
        'source': 'Edge Mapper (Firebase AI)',
      });
      expect(modernized['leisure'], 'fitness_centre');
      expect(modernized.containsKey('amenity'), isFalse);
      expect(modernized['internet_access'], 'wlan');
      expect(modernized['internet_access:fee'], 'no');
      expect(modernized['phone'], '+81-3-0000-0000');
      expect(modernized['surface'], 'sett');
      expect(modernized['wheelchair'], 'yes');
      expect(modernized.containsKey('created_by'), isFalse);
      expect(modernized['source'], 'survey');

      final notices = OsmTagStandards.findDeprecatedTags({
        'day_off': 'We',
        'shop': 'fish',
        'source': 'Edge Mapper (on-device offline)',
      });
      expect(notices.length, 3);
      expect(notices.first.wikiUrl, OsmTagStandards.openingHoursWikiUrl);

      // Invalid GPS in source is also detected and auto-fixed to survey
      final gpsSourceNotices = OsmTagStandards.findDeprecatedTags({
        'source': 'survey;GPS',
      });
      expect(gpsSourceNotices.length, 1);
      expect(gpsSourceNotices.first.canAutoFix, isTrue);
      expect(gpsSourceNotices.first.isInvalidTag, isTrue);
      expect(gpsSourceNotices.first.replacementSummary, 'source=survey');
      expect(
        OsmTagStandards.modernizeTags({'source': 'survey;GPS'})['source'],
        'survey',
      );
      expect(
        OsmTagStandards.modernizeTags({'source': 'GPS'})['source'],
        'survey',
      );

      expect(
        OsmTagStandards.wikiUrlForTag('amenity', 'cafe'),
        'https://wiki.openstreetmap.org/wiki/Tag:amenity%3Dcafe',
      );
      expect(
        OsmTagStandards.wikiUrlForTag('opening_hours', 'Tu-Su 09:00-18:00'),
        'https://wiki.openstreetmap.org/wiki/Key:opening_hours',
      );
      expect(
        OsmTagStandards.wikiUrlForTag('name:ja', '東京'),
        'https://wiki.openstreetmap.org/wiki/Key:name',
      );
    });

    test('separates non-published local tags, strips them from AI/publish/export, and sets survey source (never GPS)', () {
      // AI JSON containing deprecated day_off, camera:direction on a cafe, and software source
      final aiJson = jsonEncode({
        'summary': 'Corner Cafe',
        'fieldNotes': 'Nice wooden sign',
        'detectedLanguage': 'en',
        'osmType': 'node',
        'estimatedOffsetMeters': 7.0,
        'tags': [
          {'key': 'amenity', 'value': 'cafe'},
          {'key': 'name', 'value': 'Cedar Coffee'},
          {'key': 'opening_hours', 'value': '08:00-17:00'},
          {'key': 'day_off', 'value': 'Tuesday'},
          {'key': 'camera:direction', 'value': '135'},
          {'key': 'source', 'value': 'Edge Mapper'},
        ],
        'tagCandidates': [
          {'key': 'day_off', 'value': 'Tuesday', 'probability': 0.8},
          {'key': 'outdoor_seating', 'value': 'yes', 'probability': 0.9},
        ],
      });

      final parsedWithGps = HybridAiService.parseStructuredOsmJson(
        aiJson,
        aiSource: AiSource.firebaseCloud,
        headingDegrees: 135,
        hasGpsFix: true,
      );
      expect(parsedWithGps.tags.containsKey('day_off'), isFalse);
      expect(parsedWithGps.tags['opening_hours'], 'Mo,We-Su 08:00-17:00');
      expect(parsedWithGps.tags.containsKey('camera:direction'), isFalse);
      expect(parsedWithGps.tags['source'], 'survey');

      final parsedWithoutGps = HybridAiService.parseStructuredOsmJson(
        aiJson,
        aiSource: AiSource.firebaseCloud,
        headingDegrees: 135,
        hasGpsFix: false,
      );
      expect(parsedWithoutGps.tags['source'], 'survey');

      // Legacy saved record containing camera:direction & Edge Mapper / GPS source
      final legacyRecord = OsmRecord(
        id: 'legacy-1',
        createdAt: DateTime.utc(2026, 11, 22),
        latitude: 35.6812,
        longitude: 139.7671,
        summary: 'Legacy Cafe',
        tags: const {
          'amenity': 'cafe',
          'name': 'Old Cafe',
          'camera:direction': '90',
          'day_off': 'Monday',
          'opening_hours': '09:00-18:00',
          'source': 'survey;GPS',
        },
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.readyToUpload,
      );

      final split = OsmTagStandards.splitTagsForDisplay(legacyRecord.tags);
      expect(split.localOnly.containsKey('camera:direction'), isTrue);
      expect(split.publishable.containsKey('camera:direction'), isFalse);

      // Publishing XML strips camera:direction, modernizes day_off & source (no GPS!)
      final osc = OsmPublishService.buildOsmChangeXml(
        changesetId: 101,
        records: [legacyRecord],
      );
      expect(osc, isNot(contains('camera:direction')));
      expect(osc, isNot(contains('day_off')));
      expect(osc, isNot(contains('survey;GPS')));
      expect(osc, contains('k="opening_hours" v="Tu-Su 09:00-18:00"'));
      expect(osc, contains('k="source" v="survey"'));

      // Changeset XML uses survey source and normalizes any GPS token away
      final csXml = OsmPublishService.buildChangesetXml(comment: 'Survey');
      expect(csXml, contains('k="source" v="survey"'));
      final csXmlLegacy = OsmPublishService.buildChangesetXml(
        comment: 'Survey',
        source: 'survey;GPS',
      );
      expect(csXmlLegacy, contains('k="source" v="survey"'));

      // OSM XML export also strips camera:direction and uses survey
      final osmXml = OsmExportService.buildOsmXml(records: [legacyRecord]);
      expect(osmXml, isNot(contains('camera:direction')));
      expect(osmXml, contains('k="source" v="survey"'));

      // Surveillance cameras DO keep camera:direction as a genuine OSM tag
      final cameraSplit = OsmTagStandards.splitTagsForDisplay(const {
        'man_made': 'surveillance',
        'camera:direction': '180',
      });
      expect(cameraSplit.publishable['camera:direction'], '180');
      expect(cameraSplit.localOnly, isEmpty);
    });
  });

  group('Multi-Photo Main Location Selection, Position Error Breakdown & EXIF GPS', () {
    test('switches main POI coordinates between multiple photos, persists to DB, and supports manual pin override', () {
      final now = DateTime.utc(2026, 11, 23, 10, 0);
      final rec = OsmRecord(
        id: 'multi-loc-1',
        createdAt: now,
        photoPaths: const ['/tmp/street_view.jpg', '/tmp/entrance_closeup.jpg'],
        photoLocations: [
          PhotoLocationMeta(
            photoPath: '/tmp/street_view.jpg',
            latitude: 35.68100,
            longitude: 139.76700,
            accuracyMeters: 15.0,
            headingDegrees: 90.0,
            sourceLabel: 'Live GPS',
            capturedAt: now,
          ),
          PhotoLocationMeta(
            photoPath: '/tmp/entrance_closeup.jpg',
            latitude: 35.68125,
            longitude: 139.76740,
            accuracyMeters: 4.0,
            headingDegrees: 0.0,
            sourceLabel: 'Photo EXIF',
            capturedAt: now,
          ),
        ],
        primaryLocationPhotoIndex: 0,
        latitude: 35.68100,
        longitude: 139.76700,
        accuracyMeters: 15.0,
        headingDegrees: 90.0,
        estimatedOffsetMeters: 10.0,
        summary: 'Bakery',
        tags: const {'shop': 'bakery'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.readyToUpload,
      );

      expect(rec.effectivePrimaryPhotoIndex, 0);
      expect(rec.locationMetaForPhoto(1)?.sourceLabel, 'Photo EXIF');

      // Switch main coordinates to Photo #2 (close-up entrance with better accuracy)
      final switched = rec.selectMainLocationPhoto(1);
      expect(switched.effectivePrimaryPhotoIndex, 1);
      expect(switched.latitude, closeTo(35.68125, 1e-6));
      expect(switched.longitude, closeTo(139.76740, 1e-6));
      expect(switched.accuracyMeters, 4.0);
      expect(switched.headingDegrees, 0.0);
      expect(switched.isManualPinOverride, isFalse);

      // Manual pin override replaces extrapolated pin & drops uncertainty to manual (~2m)
      final manual = switched.withManualPinCoordinates(35.68130, 139.76742);
      expect(manual.isManualPinOverride, isTrue);
      expect(manual.effectiveLatitude, closeTo(35.68130, 1e-6));
      expect(manual.effectiveLongitude, closeTo(139.76742, 1e-6));
      expect(manual.positionUncertainty.isManualOverride, isTrue);
      expect(manual.positionUncertainty.totalCombinedErrorMeters, 2.0);
      expect(
        manual.positionUncertainty.severity,
        PositionUncertaintySeverity.highPrecision,
      );

      // DB round-trip preserves photoLocations, primaryLocationPhotoIndex & isManualPinOverride
      final restored = OsmRecord.fromDbMap(manual.toDbMap());
      expect(restored.photoLocations.length, 2);
      expect(restored.primaryLocationPhotoIndex, 1);
      expect(restored.isManualPinOverride, isTrue);
      expect(restored.photoLocations[1].sourceLabel, 'Photo EXIF');
    });

    test('computes transparent GPS measurement + extrapolation calculation error breakdown', () {
      // High precision: 4m GPS + 5m offset -> low combined error
      final tight = PositionUncertainty.compute(
        gpsAccuracyMeters: 4.0,
        headingDegrees: 45.0,
        estimatedOffsetMeters: 5.0,
        isManualOverride: false,
      );
      expect(tight.gpsMeasurementErrorMeters, 4.0);
      expect(tight.distanceCalcErrorMeters, greaterThanOrEqualTo(1.5));
      expect(tight.bearingCalcErrorMeters, greaterThan(0.5));
      expect(tight.extrapolationCalcErrorMeters, greaterThan(1.5));
      expect(tight.totalCombinedErrorMeters, greaterThan(4.0));
      expect(tight.totalCombinedErrorMeters, lessThan(8.0));
      expect(tight.severity, PositionUncertaintySeverity.highPrecision);

      // Large offset & poor GPS -> flagged as needsCorrection
      final poor = PositionUncertainty.compute(
        gpsAccuracyMeters: 25.0,
        headingDegrees: 180.0,
        estimatedOffsetMeters: 30.0,
        isManualOverride: false,
      );
      expect(poor.extrapolationCalcErrorMeters, greaterThan(8.0));
      expect(poor.totalCombinedErrorMeters, greaterThan(26.0));
      expect(poor.severity, PositionUncertaintySeverity.needsCorrection);
    });

    test('extracts GPS coordinates, heading & accuracy from JPEG EXIF APP1 bytes', () {
      // Build a minimal valid JPEG with little-endian EXIF TIFF & GPS IFD:
      // Lat = 35° 40' 52" N (35.681111°), Lon = 139° 46' 1" E (139.766944°),
      // Heading = 180°, Horizontal error = 6.5m (13/2)
      final tiff = BytesBuilder();
      void addU16(int v) =>
          tiff.add([v & 0xFF, (v >> 8) & 0xFF]);
      void addU32(int v) => tiff.add([
            v & 0xFF,
            (v >> 8) & 0xFF,
            (v >> 16) & 0xFF,
            (v >> 24) & 0xFF,
          ]);
      void addEntry(int tag, int type, int count, int valueOrOffset) {
        addU16(tag);
        addU16(type);
        addU32(count);
        addU32(valueOrOffset);
      }

      // TIFF header (8 bytes): 'II', 42, IFD0 offset = 8
      tiff.add([0x49, 0x49]);
      addU16(0x002A);
      addU32(8);

      // IFD0 at offset 8: 1 entry (12 bytes) + nextIFD (4 bytes) -> total 18 bytes, ends at 26
      addU16(1);
      addEntry(0x8825, 4, 1, 26); // GPSInfoIFDPointer -> offset 26
      addU32(0);

      // GPS IFD at offset 26: 6 entries (2 + 6*12 + 4 = 78 bytes), ends at 104
      const dataBase = 104;
      addU16(6);
      addEntry(0x0001, 2, 2, 0x4E); // GPSLatitudeRef = 'N'
      addEntry(0x0002, 5, 3, dataBase); // GPSLatitude at 104 (24 bytes)
      addEntry(0x0003, 2, 2, 0x45); // GPSLongitudeRef = 'E'
      addEntry(0x0004, 5, 3, dataBase + 24); // GPSLongitude at 128 (24 bytes)
      addEntry(0x0011, 5, 1, dataBase + 48); // GPSImgDirection at 152 (8 bytes)
      addEntry(0x001F, 5, 1, dataBase + 56); // GPSHPositioningError at 160 (8 bytes)
      addU32(0);

      // Rational values starting at offset 104
      // Lat: 35/1, 40/1, 52/1
      addU32(35); addU32(1);
      addU32(40); addU32(1);
      addU32(52); addU32(1);
      // Lon: 139/1, 46/1, 1/1
      addU32(139); addU32(1);
      addU32(46); addU32(1);
      addU32(1); addU32(1);
      // Heading: 180/1
      addU32(180); addU32(1);
      // HPositioningError: 13/2 = 6.5m
      addU32(13); addU32(2);

      final tiffBytes = tiff.toBytes();
      final segLen = 2 + 6 + tiffBytes.length;
      final jpeg = BytesBuilder()
        ..add([0xFF, 0xD8]) // SOI
        ..add([0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF]) // APP1
        ..add([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // Exif\0\0
        ..add(tiffBytes)
        ..add([0xFF, 0xD9]); // EOI

      final parsed = ExifGpsReader.extractFromBytes(jpeg.toBytes());
      expect(parsed, isNotNull);
      expect(parsed!.latitude, closeTo(35 + 40 / 60 + 52 / 3600, 1e-6));
      expect(parsed.longitude, closeTo(139 + 46 / 60 + 1 / 3600, 1e-6));
      expect(parsed.headingDegrees, closeTo(180.0, 1e-6));
      expect(parsed.accuracyMeters, closeTo(6.5, 1e-6));
    });

    test('distinguishes Add Missing Tags vs Reset & Re-analyze AI update modes clearly', () {
      expect(AiUpdateMode.enrichMerge.shortLabel, 'Add Missing Tags');
      expect(AiUpdateMode.enrichMerge.description.toLowerCase(), contains('keeps'));
      expect(AiUpdateMode.overwriteAll.shortLabel, 'Reset & Re-analyze');
      expect(AiUpdateMode.overwriteAll.description.toLowerCase(), contains('clears'));
    });
  });
}
