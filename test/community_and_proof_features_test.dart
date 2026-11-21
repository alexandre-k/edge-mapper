import 'dart:convert';
import 'dart:typed_data';

import 'package:edge_mapper/data/osm_tag_standards.dart';
import 'package:edge_mapper/firebase_options.dart';
import 'package:edge_mapper/models/hike_trail.dart';
import 'package:edge_mapper/models/mapping_bounty.dart';
import 'package:edge_mapper/models/osm_record.dart';
import 'package:edge_mapper/services/app_env_config.dart';
import 'package:edge_mapper/services/bitcoin_service.dart';
import 'package:edge_mapper/services/bounty_service.dart';
import 'package:edge_mapper/services/connectivity_service.dart';
import 'package:edge_mapper/services/e2ee_crypto_service.dart';
import 'package:edge_mapper/services/explorer_avatar_service.dart';
import 'package:edge_mapper/services/firebase_sync_service.dart';
import 'package:edge_mapper/services/gamification_service.dart';
import 'package:edge_mapper/services/ham_radio_gps_import_service.dart';
import 'package:edge_mapper/services/hybrid_ai_service.dart';
import 'package:edge_mapper/services/leaderboard_service.dart';
import 'package:edge_mapper/services/offline_tile_service.dart';
import 'package:edge_mapper/services/osm_browser_bridge.dart';
import 'package:edge_mapper/services/osm_duplicate_service.dart';
import 'package:edge_mapper/services/osm_heuristic_mapper.dart';
import 'package:edge_mapper/services/osm_publish_service.dart';
import 'package:edge_mapper/services/osm_tag_verifier_service.dart';
import 'package:edge_mapper/services/password_manager_bridge.dart';
import 'package:edge_mapper/services/secure_vault_backend.dart';
import 'package:edge_mapper/services/secure_vault_service.dart';
import 'package:edge_mapper/services/sync_key_service.dart';
import 'package:edge_mapper/services/user_preferences_service.dart';
import 'package:edge_mapper/widgets/osm_auth_sheet.dart';
import 'package:edge_mapper/widgets/qr_code_widget.dart';
import 'package:edge_mapper/widgets/responsive_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('1. RPG Explorer Avatar, Funny Nicknames & Growing Characteristics', () {
    test('generates unique deterministic avatars per user seed', () {
      final a1 = ExplorerAvatarService.buildAvatar(
        seed: 'user-alpha-123',
        level: 3,
        xp: 300,
        recordsCount: 5,
        multiPhotoRecordsCount: 1,
        multilingualRecordsCount: 2,
        offlineRecordsCount: 1,
        totalTrailKm: 2.5,
        activeDayStreak: 3,
      );
      final a2 = ExplorerAvatarService.buildAvatar(
        seed: 'user-alpha-123',
        level: 3,
        xp: 300,
        recordsCount: 5,
        multiPhotoRecordsCount: 1,
        multilingualRecordsCount: 2,
        offlineRecordsCount: 1,
        totalTrailKm: 2.5,
        activeDayStreak: 3,
      );
      final b = ExplorerAvatarService.buildAvatar(
        seed: 'user-beta-999',
        level: 3,
        xp: 300,
        recordsCount: 5,
        multiPhotoRecordsCount: 1,
        multilingualRecordsCount: 2,
        offlineRecordsCount: 1,
        totalTrailKm: 2.5,
        activeDayStreak: 3,
      );

      expect(a1.primaryColor, equals(a2.primaryColor));
      expect(a1.funnyNickname, equals(a2.funnyNickname));
      expect(
        a1.primaryColor != b.primaryColor ||
            a1.cloakColor != b.cloakColor ||
            a1.explorerClass != b.explorerClass,
        isTrue,
      );
    });

    test('evolves funny nicknames, RPG gear & characteristics as XP grows', () {
      final lv1 = ExplorerAvatarService.buildAvatar(
        seed: 'seed-vasco-test',
        level: 1,
        xp: 25,
        recordsCount: 1,
        multiPhotoRecordsCount: 0,
        multilingualRecordsCount: 0,
        offlineRecordsCount: 0,
        totalTrailKm: 0,
        activeDayStreak: 1,
      );
      final lv5 = ExplorerAvatarService.buildAvatar(
        seed: 'seed-vasco-test',
        level: 5,
        xp: 900,
        recordsCount: 15,
        multiPhotoRecordsCount: 4,
        multilingualRecordsCount: 6,
        offlineRecordsCount: 3,
        totalTrailKm: 8.5,
        activeDayStreak: 5,
      );

      expect(lv5.funnyNickname, isNot(equals(lv1.funnyNickname)));
      expect(lv5.unlockedNicknameHistory.length, equals(5));
      expect(lv5.characteristics.length, greaterThan(lv1.characteristics.length));
      expect(lv5.stats.totalPower, greaterThan(lv1.stats.totalPower));
      expect(lv5.gearName, isNot(equals(lv1.gearName)));
    });
  });

  group('2. Pre-Upload OpenStreetMap Duplicate Detection (POIs & Tracks)', () {
    test('identifies OSM duplicates & local batch duplicates and keeps only unique POIs', () async {
      final now = DateTime.now();
      final dupCafe = OsmRecord(
        id: 'rec-dup-cafe',
        createdAt: now,
        latitude: 35.68120,
        longitude: 139.76710,
        summary: 'Blue Bottle Coffee',
        tags: const {'amenity': 'cafe', 'name': 'Blue Bottle Coffee'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.readyToUpload,
      );
      final uniqueBench = OsmRecord(
        id: 'rec-unique-bench',
        createdAt: now,
        latitude: 35.68500,
        longitude: 139.77100,
        summary: 'Wooden Park Bench',
        tags: const {'amenity': 'bench', 'material': 'wood'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.readyToUpload,
      );
      final localSelfDupBench = OsmRecord(
        id: 'rec-local-dup-bench',
        createdAt: now,
        latitude: 35.68503,
        longitude: 139.77102,
        summary: 'Wooden Park Bench',
        tags: const {'amenity': 'bench', 'material': 'wood'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.readyToUpload,
      );

      final existingOsm = [
        const NearbyOsmElement(
          type: 'node',
          id: 987654321,
          latitude: 35.68122,
          longitude: 139.76712,
          tags: {'amenity': 'cafe', 'name': 'Blue Bottle Coffee'},
        ),
      ];

      final service = OsmDuplicateService();
      final report = await service.checkDuplicates(
        records: [dupCafe, uniqueBench, localSelfDupBench],
        mockNearbyElements: existingOsm,
      );

      expect(report.hasAnyDuplicates, isTrue);
      expect(report.duplicateRecords.map((r) => r.id), contains('rec-dup-cafe'));
      expect(
        report.duplicateRecords.map((r) => r.id),
        contains('rec-local-dup-bench'),
      );
      expect(
        report.nonDuplicateRecords.map((r) => r.id),
        equals(['rec-unique-bench']),
      );
    });

    test('detects overlapping OSM highway way for recorded trail', () {
      final now = DateTime.now();
      final trail = HikeTrail(
        id: 'trail-overlap',
        name: 'Park Path',
        startedAt: now,
        isActive: false,
        tags: const {'highway': 'footway'},
        points: [
          TrailPoint(trailId: 'trail-overlap', latitude: 48.85660, longitude: 2.35220, recordedAt: now),
          TrailPoint(trailId: 'trail-overlap', latitude: 48.85670, longitude: 2.35230, recordedAt: now),
          TrailPoint(trailId: 'trail-overlap', latitude: 48.85680, longitude: 2.35240, recordedAt: now),
        ],
      );

      final overpassJson = jsonEncode({
        'elements': [
          {
            'type': 'way',
            'id': 445566,
            'tags': {'highway': 'footway', 'name': 'Allée du Parc'},
            'geometry': [
              {'lat': 48.85661, 'lon': 2.35221},
              {'lat': 48.85671, 'lon': 2.35231},
              {'lat': 48.85681, 'lon': 2.35241},
            ],
          },
        ],
      });

      final parsed = OsmDuplicateService.parseOverpassJson(overpassJson);
      final status = OsmDuplicateService.evaluateTrailDuplicates(trail, parsed);

      expect(status.isDuplicate, isTrue);
      expect(status.overlapFraction, greaterThanOrEqualTo(0.95));
      expect(status.matches.first.existingOsmId, equals(445566));
    });
  });

  group('3. Bitcoin Donations (Env Config, P2TR, Silent Payment, Lightning, BOLT 12, BTCPay) & QR Code', () {
    // BIP-341 Taproot (P2TR), BIP-352 Silent Payment, BOLT 12 & BTCPay test vectors
    const testP2tr =
        'bc1p5d7rjq7g6rdk2yhzks9smlaqtedr4dekq08ge8ztwac72sfr9rusxg3297';
    const testSegwit = 'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh';
    const testSilentPayment =
        'sp1qqgste7k9hx0qftg6qmwlkqtwuy6cycyavzmzj85c6qdfjdpdjtdgqjuexzk6murw56suy3e0rd2cgqvycxttddwsvgxe2usfpxumr70xc9rmdjhw';
    const testLightning = 'mapper@example.org';
    final testBolt12Offer = 'lno1${'q' * 380}';
    final testBolt12Uri = 'bitcoin:?lno=$testBolt12Offer';
    const testBtcPayUrl = 'https://btcpay.example.org/apps/abc123/pos';

    test('validates P2TR, SegWit, Silent Payments, Lightning, BOLT 12, BIP-321 URIs & BTCPay URLs', () {
      expect(BitcoinService.detectAddressKind(testP2tr), equals(BitcoinAddressKind.p2tr));
      expect(BitcoinService.detectAddressKind(testSegwit), equals(BitcoinAddressKind.segwit));
      expect(BitcoinService.detectAddressKind(testSilentPayment), equals(BitcoinAddressKind.silentPayment));
      expect(BitcoinService.detectAddressKind(testLightning), equals(BitcoinAddressKind.lightningAddress));
      expect(BitcoinService.detectAddressKind(testBolt12Offer), equals(BitcoinAddressKind.bolt12Offer));
      expect(BitcoinService.detectAddressKind(testBolt12Uri), equals(BitcoinAddressKind.bitcoinUri));
      expect(BitcoinService.detectAddressKind(testBtcPayUrl), equals(BitcoinAddressKind.btcPayServer));

      expect(BitcoinService.isValidBitcoinOrLightningAddress(testP2tr), isTrue);
      expect(BitcoinService.isValidBitcoinOrLightningAddress(testSilentPayment), isTrue);
      expect(BitcoinService.isValidBitcoinOrLightningAddress(testLightning), isTrue);
      expect(BitcoinService.isValidBitcoinOrLightningAddress(testBolt12Uri), isTrue);
      expect(BitcoinService.isValidBitcoinOrLightningAddress(testBtcPayUrl), isTrue);
      expect(BitcoinService.isValidBitcoinOrLightningAddress('not-an-address'), isFalse);
      expect(BitcoinService.isValidBitcoinOrLightningAddress('bitcoin:invalid'), isFalse);
      expect(BitcoinService.formatSats(50000), equals('50,000 sats'));
    });

    test('builds standards-compliant BIP-21 / BIP-321 URIs for P2TR, Silent Payment, BOLT 12, Lightning & BTCPay', () {
      // Taproot P2TR on-chain BIP-21
      final p2trUri = BitcoinService.buildBip21Uri(
        address: testP2tr,
        amountSats: 10000,
        label: 'Edge Mapper Dev',
      );
      expect(p2trUri, startsWith('bitcoin:$testP2tr?'));
      expect(p2trUri, contains('amount=0.0001'));
      expect(p2trUri, contains('label=Edge+Mapper+Dev'));

      // Silent Payment MUST use BIP-321 query param `?sp=` (never path `bitcoin:sp1...`)
      final spUri = BitcoinService.buildBip21Uri(
        address: testSilentPayment,
        amountSats: 2100,
      );
      expect(spUri, startsWith('bitcoin:?sp=$testSilentPayment'));
      expect(spUri, isNot(startsWith('bitcoin:$testSilentPayment')));
      expect(spUri, contains('amount=0.000021'));

      // BOLT 12 BIP-321 URI preserves `lno=` verbatim and appends amount cleanly
      final lnoUri = BitcoinService.buildBip21Uri(
        address: testBolt12Uri,
        amountSats: 10000,
        label: 'Ignored for compact BOLT12 QR',
      );
      expect(lnoUri, startsWith('bitcoin:?lno=$testBolt12Offer'));
      expect(lnoUri, contains('&amount=0.0001'));
      expect(lnoUri, isNot(contains('label=')));

      // Lightning address (sync fallback URI)
      expect(
        BitcoinService.buildPaymentUri(destination: testLightning, amountSats: 2100),
        equals('lightning:$testLightning'),
      );

      // BTCPay Server passthrough
      expect(
        BitcoinService.buildPaymentUri(destination: testBtcPayUrl, amountSats: 10000),
        equals(testBtcPayUrl),
      );
    });

    test('resolves exact-amount BOLT 11 invoice via LNURL-pay (LUD-16) and rejects tampered/SSRF responses', () async {
      const valid2100Invoice = 'lnbc21u1p0qqqqqqqqqq6n7rmx';
      const hijacked1BtcInvoice = 'lnbc11p0qqqqqqqqqql5wwhn';

      final mockLnurlClient = MockClient((req) async {
        if (req.url.toString() == 'https://example.org/.well-known/lnurlp/mapper') {
          return http.Response(
            jsonEncode({
              'callback': 'https://example.org/lnurlp/mapper/callback',
              'minSendable': 1000,
              'maxSendable': 100000000,
              'commentAllowed': 40,
            }),
            200,
          );
        }
        if (req.url.path == '/lnurlp/mapper/callback') {
          expect(req.url.queryParameters['amount'], equals('2100000'));
          expect(req.url.queryParameters['comment'], equals('Thanks!'));
          return http.Response(
            jsonEncode({'pr': valid2100Invoice}),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final resolved = await BitcoinService.resolveLightningAddressInvoiceUri(
        lightningAddress: testLightning,
        amountSats: 2100,
        comment: 'Thanks!',
        client: mockLnurlClient,
      );
      expect(resolved, equals('lightning:$valid2100Invoice'));

      // Rejects hijacked BOLT 11 invoice whose amount does not match requested sats
      final hijackClient = MockClient((req) async {
        if (req.url.path == '/.well-known/lnurlp/mapper') {
          return http.Response(
            jsonEncode({'callback': 'https://example.org/cb'}),
            200,
          );
        }
        return http.Response(jsonEncode({'pr': hijacked1BtcInvoice}), 200);
      });
      expect(
        await BitcoinService.resolveLightningAddressInvoiceUri(
          lightningAddress: testLightning,
          amountSats: 2100,
          client: hijackClient,
        ),
        isNull,
      );

      // Rejects SSRF callback targeting cloud metadata / private IP
      final ssrfClient = MockClient((req) async {
        return http.Response(
          jsonEncode({'callback': 'https://169.254.169.254/latest/meta-data/'}),
          200,
        );
      });
      expect(
        await BitcoinService.resolveLightningAddressInvoiceUri(
          lightningAddress: testLightning,
          amountSats: 2100,
          client: ssrfClient,
        ),
        isNull,
      );

      // Rejects corrupted Bech32m checksum & rejects https:// phishing URLs when allowBtcPayUrl=false
      expect(
        BitcoinService.isValidBitcoinOrLightningAddress(
          'bc1p5d7rjq7g6rdk2yhzks9smlaqtedr4dekq08ge8ztwac72sfr9rusxg3298',
        ),
        isFalse,
      );
      expect(
        BitcoinService.isValidBitcoinOrLightningAddress(
          'https://evil.example/drain',
          allowBtcPayUrl: false,
        ),
        isFalse,
      );
    });

    test('loads multi-rail donation config from environment with zero hardcoded defaults', () {
      const emptyConfig = BitcoinDonationConfig();
      expect(emptyConfig.isConfigured, isFalse);
      expect(emptyConfig.availableOptions, isEmpty);

      final multiConfig = BitcoinDonationConfig(
        btcPayUrl: testBtcPayUrl,
        bitcoinUri: testBolt12Uri,
        silentPaymentAddress: testSilentPayment,
        lightningAddress: testLightning,
        p2trAddress: testP2tr,
      );
      expect(multiConfig.isConfigured, isTrue);
      expect(
        multiConfig.availableOptions.map((o) => o.method).toList(),
        equals([
          BitcoinPaymentMethod.btcPayServer,
          BitcoinPaymentMethod.bitcoinUri,
          BitcoinPaymentMethod.silentPayment,
          BitcoinPaymentMethod.lightning,
          BitcoinPaymentMethod.onChain,
        ]),
      );

      // Extracts embedded P2TR & Silent Payment rails from a unified BIP-321 URI automatically
      const extracted = BitcoinDonationConfig(
        bitcoinUri: 'bitcoin:$testP2tr?sp=$testSilentPayment',
      );
      expect(extracted.effectiveOnChainAddress, equals(testP2tr));
      expect(extracted.effectiveSilentPaymentAddress, equals(testSilentPayment));
      expect(
        extracted.availableOptions.map((o) => o.method),
        containsAll([
          BitcoinPaymentMethod.bitcoinUri,
          BitcoinPaymentMethod.silentPayment,
          BitcoinPaymentMethod.onChain,
        ]),
      );
    });

    test('encodes short P2TR, Silent Payment & 400+ byte BOLT 12 URIs into valid QR matrices without truncation', () {
      // Standard BIP-21 P2TR QR
      final p2trQr = QrMatrix.encode(
        BitcoinService.buildBip21Uri(address: testP2tr, amountSats: 2100),
      );
      expect(p2trQr.size, equals(17 + p2trQr.version * 4));
      expect(p2trQr.modules[0][0], isTrue);
      expect(p2trQr.modules[0][6], isTrue);
      expect(p2trQr.modules[3][3], isTrue);
      expect(p2trQr.modules[1][1], isFalse);
      expect(p2trQr.modules[p2trQr.size - 8][8], isTrue);

      // Silent Payment BIP-321 QR (~145 bytes -> Version 7)
      final spUri = BitcoinService.buildBip21Uri(
        address: testSilentPayment,
        amountSats: 10000,
      );
      final spQr = QrMatrix.encode(spUri);
      expect(spQr.version, greaterThanOrEqualTo(7));
      expect(spQr.size, equals(17 + spQr.version * 4));
      // Verify alignment pattern center at (6, 22) is dark on V7 (not skipped by timing overlap!)
      if (spQr.version == 7) {
        expect(spQr.modules[6][22], isTrue);
        expect(spQr.modules[22][6], isTrue);
      }

      // Long BOLT 12 BIP-321 URI (~411 bytes -> Version 13, 16-bit char count, 4 RS blocks)
      final bolt12Qr = QrMatrix.encode(
        BitcoinService.buildBip21Uri(address: testBolt12Uri, amountSats: 10000),
      );
      expect(bolt12Qr.version, equals(13));
      expect(bolt12Qr.size, equals(69));
      expect(bolt12Qr.modules[0][0], isTrue);
      expect(bolt12Qr.modules[bolt12Qr.size - 8][8], isTrue);
    });

    test('validates any active environment-supplied developer donation options & their QR matrices', () {
      final envConfig = BitcoinService.developerDonationConfig;
      final anyEnvSet = BitcoinDonationConfig.envDonationUri.isNotEmpty ||
          BitcoinDonationConfig.envP2trAddress.isNotEmpty ||
          BitcoinDonationConfig.envFallbackAddress.isNotEmpty ||
          BitcoinDonationConfig.envLightningAddress.isNotEmpty ||
          BitcoinDonationConfig.envSilentPaymentAddress.isNotEmpty ||
          BitcoinDonationConfig.envBolt12Offer.isNotEmpty ||
          BitcoinDonationConfig.envBtcPayUrl.isNotEmpty;

      expect(envConfig.isConfigured, equals(anyEnvSet));
      for (final opt in envConfig.availableOptions) {
        final uri = opt.buildPaymentUri(amountSats: 10000);
        expect(uri, isNotEmpty);
        final qr = QrMatrix.encode(uri);
        expect(qr.size, equals(17 + qr.version * 4));
        expect(qr.modules[0][0], isTrue);
        expect(qr.modules[qr.size - 8][8], isTrue);
      }
    });
  });

  group('4. Multi-Photo Capture & AI Feature Merging', () {
    test('persists multiple photoPaths on OsmRecord with legacy photoPath compatibility', () {
      final rec = OsmRecord(
        id: 'multi-1',
        createdAt: DateTime.utc(2026, 11, 23),
        photoPaths: const ['/tmp/front.jpg', '/tmp/hours.jpg', '/tmp/ramp.jpg'],
        latitude: 35.68,
        longitude: 139.76,
        summary: 'Corner Cafe',
        tags: const {'amenity': 'cafe'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.aiEnriched,
      );

      expect(rec.photoPath, equals('/tmp/front.jpg'));
      expect(rec.hasMultiplePhotos, isTrue);

      final roundTripped = OsmRecord.fromDbMap(rec.toDbMap());
      expect(roundTripped.allPhotoPaths.length, equals(3));
      expect(roundTripped.allPhotoPaths[1], equals('/tmp/hours.jpg'));
    });

    test('merges multiple per-photo AI results into one combined POI feature set', () {
      const photo1 = OsmInferenceResult(
        summary: 'Sakura Roasters Cafe',
        fieldNotes: 'Timber storefront with outdoor bench',
        detectedLanguage: 'en',
        osmType: 'node',
        estimatedOffsetMeters: 6.0,
        distanceReasoning: 'Front facade ~6m',
        tags: {'amenity': 'cafe', 'name': 'Sakura Roasters'},
        detectedLabels: ['Cafe', 'Storefront'],
        tagCandidates: {'amenity=cafe': 0.96},
        aiSource: AiSource.firebaseCloud,
      );
      const photo2 = OsmInferenceResult(
        summary: 'Opening Hours & Ramp',
        fieldNotes: 'Step-free entrance with Bitcoin accepted sticker',
        detectedLanguage: 'en',
        osmType: 'node',
        estimatedOffsetMeters: 4.0,
        distanceReasoning: 'Door sign ~4m',
        tags: {
          'opening_hours': 'Mo-Fr 08:00-19:00',
          'wheelchair': 'yes',
          'currency:XBT': 'yes',
        },
        detectedLabels: ['Door', 'Sign'],
        tagCandidates: {'wheelchair=yes': 0.92, 'opening_hours=Mo-Fr 08:00-19:00': 0.88},
        aiSource: AiSource.firebaseCloud,
      );

      final merged = HybridAiService.mergeInferenceResults([photo1, photo2]);
      expect(merged.tags['amenity'], equals('cafe'));
      expect(merged.tags['name'], equals('Sakura Roasters'));
      expect(merged.tags['opening_hours'], equals('Mo-Fr 08:00-19:00'));
      expect(merged.tags['wheelchair'], equals('yes'));
      expect(merged.tags['currency:XBT'], equals('yes'));
      expect(merged.fieldNotes, contains('Step-free entrance'));
      expect(merged.estimatedOffsetMeters, closeTo(5.0, 0.01));
    });
  });

  group('5. Real OpenStreetMap Local Guild Leaderboard', () {
    test('loads real OSM contributors near the POI, excludes giant non-local edits, computes XP from mapped volume, and has zero fake users', () async {
      final prefs = UserPreferencesService();
      final conn = ConnectivityService(initialHasNetwork: true);
      final fb = FirebaseSyncService(prefs: prefs);

      final mockClient = MockClient((req) async {
        if (req.url.path.endsWith('/api/0.6/changesets.json')) {
          return http.Response(
            jsonEncode({
              'changesets': [
                // Real local mapper 1 near Tokyo Station POI (2 local changesets = 35 edits)
                {
                  'id': 1001,
                  'uid': 4201,
                  'user': 'taro_tokyo',
                  'changes_count': 25,
                  'min_lat': 35.6805,
                  'max_lat': 35.6820,
                  'min_lon': 139.7660,
                  'max_lon': 139.7680,
                  'closed_at': '2026-11-20T09:00:00Z',
                },
                {
                  'id': 1002,
                  'uid': 4201,
                  'user': 'taro_tokyo',
                  'changes_count': 10,
                  'min_lat': 35.6810,
                  'max_lat': 35.6816,
                  'min_lon': 139.7668,
                  'max_lon': 139.7675,
                  'closed_at': '2026-11-22T12:00:00Z',
                },
                // Real local mapper 2 near POI (1 small local changeset = 4 edits)
                {
                  'id': 1003,
                  'uid': 4202,
                  'user': 'hanako_walks',
                  'changes_count': 4,
                  'min_lat': 35.6811,
                  'max_lat': 35.6815,
                  'min_lon': 139.7670,
                  'max_lon': 139.7674,
                  'closed_at': '2026-11-21T15:30:00Z',
                },
                // Giant nationwide armchair edit (span > 0.35°) -> MUST be excluded!
                {
                  'id': 1004,
                  'uid': 9999,
                  'user': 'global_bot_import',
                  'changes_count': 5000,
                  'min_lat': 31.0,
                  'max_lat': 41.0,
                  'min_lon': 130.0,
                  'max_lon': 145.0,
                  'closed_at': '2026-11-22T01:00:00Z',
                },
              ],
            }),
            200,
          );
        }
        if (req.url.path.endsWith('/api/0.6/users.json')) {
          return http.Response(
            jsonEncode({
              'users': [
                {
                  'user': {
                    'id': 4201,
                    'display_name': 'taro_tokyo',
                    'account_created': '2019-04-12T00:00:00Z',
                    'changesets': {'count': 180},
                    'traces': {'count': 6},
                  },
                },
                {
                  'user': {
                    'id': 4202,
                    'display_name': 'hanako_walks',
                    'account_created': '2023-08-01T00:00:00Z',
                    'changesets': {'count': 12},
                    'traces': {'count': 1},
                  },
                },
              ],
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final lb = LeaderboardService(
        prefs: prefs,
        firebaseSync: fb,
        connectivity: conn,
        client: mockClient,
      );

      final rookieProfile = GamificationService.computeProfile(
        records: const [],
        trails: const [],
        avatarSeed: 'rookie',
      );

      // Before fetching online, ZERO fictional benchmark users appear
      final initialSnap = lb.buildSnapshot(
        currentProfile: rookieProfile,
        recordsCount: 0,
        totalTrailKm: 0,
        verifiedProofsCount: 0,
      );
      expect(initialSnap.totalMappers, equals(1));
      expect(initialSnap.entries.single.isCurrentUser, isTrue);

      // Fetch real OSM contributors near Tokyo Station POI
      await lb.fetchNearbyOsmMappers(
        latitude: 35.6812,
        longitude: 139.7671,
        poiLabel: 'Tokyo Station',
        radiusMeters: 2000,
      );

      final snap = lb.buildSnapshot(
        currentProfile: rookieProfile,
        recordsCount: 0,
        totalTrailKm: 0,
        verifiedProofsCount: 0,
      );

      expect(snap.syncedWithCloud, isTrue);
      expect(snap.anchorLabel, equals('Tokyo Station'));
      expect(snap.totalMappers, equals(3)); // taro_tokyo, hanako_walks, You
      expect(
        snap.entries.map((e) => e.displayName),
        isNot(contains('global_bot_import')),
      );
      expect(
        snap.entries.map((e) => e.displayName),
        isNot(contains('Kenji_T')),
      );

      // Verify exact real OSM numbers & XP calculation for #1 (taro_tokyo)
      final first = snap.entries.first;
      expect(first.displayName, equals('taro_tokyo'));
      expect(first.osmUserId, equals(4201));
      expect(first.osmAreaChangesCount, equals(35));
      expect(first.osmAreaChangesetsCount, equals(2));
      expect(first.osmLifetimeChangesets, equals(180));
      expect(first.osmTracesCount, equals(6));
      expect(
        first.effectiveOsmProfileUrl,
        equals('https://www.openstreetmap.org/user/taro_tokyo'),
      );
      expect(
        first.xp,
        equals(
          LeaderboardService.computeRealOsmXp(
            areaChangesCount: 35,
            areaChangesetsCount: 2,
            lifetimeChangesetsCount: 180,
            tracesCount: 6,
          ),
        ),
      );
      expect(first.distanceToPoiMeters, isNotNull);
      expect(first.distanceToPoiMeters!, lessThan(500));

      // Current rookie user is last & gets incentive to overtake hanako_walks
      expect(snap.isLast, isTrue);
      expect(snap.nextRivalAbove?.displayName, equals('hanako_walks'));
      expect(snap.incentiveMessage, contains('overtake hanako_walks'));

      // High-XP mapper reaches #1 above taro_tokyo
      final manyRecords = List.generate(
        40,
        (i) => OsmRecord(
          id: 'r-$i',
          createdAt: DateTime.now(),
          photoPaths: const ['a.jpg', 'b.jpg'],
          latitude: 35.68,
          longitude: 139.76,
          summary: 'Place $i',
          tags: const {
            'amenity': 'cafe',
            'name': 'Cafe',
            'name:en': 'Cafe',
            'wheelchair': 'yes',
            'outdoor_seating': 'yes',
          },
          aiSource: AiSource.firebaseCloud,
          status: RecordStatus.uploaded,
        ),
      );
      final legendProfile = GamificationService.computeProfile(
        records: manyRecords,
        trails: const [],
        avatarSeed: 'legend',
      );
      final legendSnap = lb.buildSnapshot(
        currentProfile: legendProfile,
        recordsCount: manyRecords.length,
        totalTrailKm: 15.0,
        verifiedProofsCount: 25,
      );
      expect(legendSnap.isFirst, isTrue);
      expect(legendSnap.standingLabel, contains('#1'));

      // Signed-in OSM user matches & merges with their own real OSM entry cleanly
      await prefs.setOsmAuthSession(
        accessToken: 'tok',
        username: 'hanako_walks',
        userId: 4202,
      );
      final signedInSnap = lb.buildSnapshot(
        currentProfile: rookieProfile,
        recordsCount: 0,
        totalTrailKm: 0,
        verifiedProofsCount: 0,
      );
      // Still 2 unique entries (taro_tokyo + merged hanako_walks), not duplicated!
      expect(signedInSnap.totalMappers, equals(2));
      expect(signedInSnap.currentUser.displayName, equals('hanako_walks'));
      expect(signedInSnap.currentUser.osmAreaChangesCount, equals(4));
      expect(signedInSnap.currentUser.osmLifetimeChangesets, equals(12));
    });
  });

  group('6. Bitcoin Mapping Bounties', () {
    test('formats shareable Bitcoin mapping bounty announcement text', () {
      final bounty = MappingBounty(
        id: 'bounty-1',
        title: 'Survey EV chargers at North Lot',
        description: 'Need socket count & operator tags',
        areaLabel: 'North Transit Lot',
        targetLatitude: 35.6812,
        targetLongitude: 139.7671,
        radiusMeters: 250,
        requestedTags: const ['amenity=charging_station', 'capacity'],
        rewardSats: 25000,
        creatorExplorerId: 'creator-1',
        creatorName: 'Alex',
        createdAt: DateTime.utc(2026, 11, 23),
      );

      final text = BountyService.buildSocialAnnouncementText(bounty);
      expect(text, contains('25,000 sats'));
      expect(text, contains('North Transit Lot'));
      expect(text, contains('amenity=charging_station'));
    });
  });

  group('Main vs Secondary Language Hierarchy & Unicode-Safe Map Cache', () {
    test('keeps main language primary and fallback language strictly secondary, while allowing English-only names', () async {
      final prefs = UserPreferencesService();
      await prefs.setPrimaryLanguage('fr');
      await prefs.setSecondaryLanguage('en');

      expect(prefs.primaryLanguage, equals('fr'));
      expect(prefs.secondaryLanguage, equals('en'));
      // Abroad in Japan: Main language (fr) is primary, fallback (en) is strictly secondary
      expect(prefs.resolveUserLanguageForCountry('ja'), equals('fr'));
      expect(prefs.resolveSecondaryLanguageForCountry('ja'), equals('en'));
      // In France: Main language matches country, so secondary (en) is companion tag
      expect(prefs.resolveUserLanguageForCountry('fr'), equals('en'));

      // English-only signage: English name is kept cleanly without faking name:fr
      final englishOnly = OsmHeuristicMapper.inferFromOnDeviceSignals(
        imageLabels: const ['Coffee', 'Cafe'],
        ocrLines: const ['Blue Bottle Coffee'],
        countryLanguage: 'ja',
        primaryLanguage: 'fr',
        confidentLanguages: const ['fr', 'en'],
        preferredFallbackLanguage: 'en',
      );
      expect(englishOnly.tags['name'], equals('Blue Bottle Coffee'));
      expect(englishOnly.tags['name:en'], equals('Blue Bottle Coffee'));
      expect(englishOnly.tags.containsKey('name:fr'), isFalse);

      // Bilingual Japanese + French signage uses Main language (fr)
      final bilingualJaFr = OsmHeuristicMapper.inferFromOnDeviceSignals(
        imageLabels: const ['Building'],
        ocrLines: const ['太陽パン屋', 'Boulangerie du Soleil'],
        countryLanguage: 'ja',
        primaryLanguage: 'fr',
        confidentLanguages: const ['fr', 'en'],
        preferredFallbackLanguage: 'en',
      );
      expect(bilingualJaFr.tags['name'], equals('太陽パン屋'));
      expect(bilingualJaFr.tags['name:ja'], equals('太陽パン屋'));
      expect(bilingualJaFr.tags['name:fr'], equals('Boulangerie du Soleil'));
    });

    test('uses OpenStreetMap Standard (Unicode/CJK-safe) primary tiles and validates raster magic bytes', () {
      const tokyoTile = TileCoord(15, 29106, 12903);
      final streetCandidates = MapTileStyle.osmStreets.tileCandidateUris(tokyoTile);
      expect(streetCandidates.first.host, equals('tile.openstreetmap.org'));

      final topoCandidates = MapTileStyle.topo.tileCandidateUris(tokyoTile);
      expect(topoCandidates.last.host, equals('tile.openstreetmap.org'));

      // Valid PNG header passes; HTML error page is rejected from cache
      final validPng = Uint8List.fromList(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13],
      );
      final htmlErr = Uint8List.fromList(utf8.encode('<html>429 Too Many</html>'));
      expect(OfflineTileService.isValidRasterTileBytes(validPng), isTrue);
      expect(OfflineTileService.isValidRasterTileBytes(htmlErr), isFalse);
    });
  });

  group('Duplicate Check Server Warning & Selective Tag Merge on Existing OSM POI', () {
    test('returns serverWarning (NEVER passed) when remote OSM/Overpass servers return HTTP 502', () async {
      final mockClient = MockClient((_) async => http.Response('Bad Gateway', 502));
      final service = OsmDuplicateService(client: mockClient);

      final rec = OsmRecord(
        id: 'rec-502',
        createdAt: DateTime.now(),
        latitude: 35.6812,
        longitude: 139.7671,
        summary: 'ふなっこ畑',
        tags: const {'shop': 'farm', 'name': 'ふなっこ畑'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.readyToUpload,
      );

      final report = await service.checkDuplicates(
        records: [rec],
        isOnline: true,
      );

      expect(report.usedRemoteOsmCheck, isFalse);
      expect(report.outcome, equals(DuplicateCheckOutcome.serverWarning));
      expect(report.outcome, isNot(equals(DuplicateCheckOutcome.passed)));
      expect(report.warningMessage, contains('502'));
    });

    test('uses OSM API v0.6 map.json, exposes existing tags, suggests new tag subset, and builds <modify> OsmChange XML', () async {
      final osmMapResponse = jsonEncode({
        'elements': [
          {
            'type': 'node',
            'id': 55443322,
            'version': 4,
            'lat': 35.68121,
            'lon': 139.76711,
            'tags': {
              'shop': 'farm',
              'name': 'ふなっこ畑',
              'phone': '+81-47-000-0000',
            },
          },
        ],
      });

      final mockClient = MockClient((req) async {
        expect(req.url.path, contains('/api/0.6/map.json'));
        return http.Response.bytes(
          utf8.encode(osmMapResponse),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = OsmDuplicateService(client: mockClient);
      final rec = OsmRecord(
        id: 'rec-farm',
        createdAt: DateTime.now(),
        latitude: 35.68120,
        longitude: 139.76710,
        summary: 'ふなっこ畑',
        tags: const {
          'shop': 'farm',
          'name': 'ふなっこ畑',
          'name:en': 'Funakko Hatake',
          'opening_hours': 'Tu-Su 09:30-18:00',
          'wheelchair': 'yes',
          'phone': '+81-47-111-2222',
          'source': 'Edge Mapper',
          'camera:direction': '90',
        },
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.readyToUpload,
      );

      final report = await service.checkDuplicates(
        records: [rec],
        isOnline: true,
      );

      expect(report.usedRemoteOsmCheck, isTrue);
      expect(report.outcome, equals(DuplicateCheckOutcome.duplicatesFound));
      final match = report.statusForRecord('rec-farm')!.strongestMatch!;
      expect(match.existingOsmId, equals(55443322));
      expect(match.existingElement?.version, equals(4));
      expect(match.existingTags['name'], equals('ふなっこ畑'));
      // Suggests strictly new tags (excluding internal source / camera:direction)
      expect(match.newTagsAvailable.keys, containsAll(['name:en', 'opening_hours', 'wheelchair']));
      expect(match.newTagsAvailable.containsKey('source'), isFalse);
      expect(match.newTagsAvailable.containsKey('camera:direction'), isFalse);
      // Detects differing existing tag
      expect(match.differingTagsAvailable.single.key, equals('phone'));

      // User selectively chooses ONLY a subset: opening_hours + wheelchair (skipping name:en & phone)
      final tagUpdate = OsmElementTagUpdate(
        elementType: match.existingOsmType,
        elementId: match.existingOsmId,
        version: match.existingElement!.version,
        latitude: match.existingElement!.latitude,
        longitude: match.existingElement!.longitude,
        existingTags: match.existingTags,
        selectedNewTags: {
          'opening_hours': match.newTagsAvailable['opening_hours']!,
          'wheelchair': match.newTagsAvailable['wheelchair']!,
        },
        sourceRecordId: rec.id,
      );

      final issues = OsmPublishService.validateForPublish(tagUpdates: [tagUpdate]);
      expect(issues.where((i) => i.isBlocking), isEmpty);

      final oscXml = OsmPublishService.buildOsmChangeXml(
        changesetId: 777,
        tagUpdates: [tagUpdate],
      );
      expect(oscXml, contains('<modify>'));
      expect(oscXml, isNot(contains('<create>')));
      expect(oscXml, contains('id="55443322" version="4" changeset="777"'));
      // Preserves existing OSM tags
      expect(oscXml, contains('<tag k="name" v="ふなっこ畑"/>'));
      expect(oscXml, contains('<tag k="phone" v="+81-47-000-0000"/>'));
      // Adds ONLY selected subset
      expect(oscXml, contains('<tag k="opening_hours" v="Tu-Su 09:30-18:00"/>'));
      expect(oscXml, contains('<tag k="wheelchair" v="yes"/>'));
      expect(oscXml, isNot(contains('Funakko Hatake')));

      final diff = OsmPublishService.parseDiffResult(
        '<diffResult><node old_id="55443322" new_id="55443322" new_version="5"/></diffResult>',
      );
      expect(diff.updatedNodeIds, equals([55443322]));
      expect(diff.createdNodeIds, isEmpty);
    });

    test('detects modified tags & upstream-only tags and supports removing tags upstream in <modify> OsmChange XML', () {
      final localRecord = OsmRecord(
        id: 'rec-republish',
        createdAt: DateTime.utc(2026, 11, 23),
        latitude: 35.68120,
        longitude: 139.76710,
        summary: 'My Cafe',
        tags: const {
          'amenity': 'cafe',
          'name': 'My Cafe',
          'opening_hours': 'Mo,Tu,Th-Su 09:00-18:00',
          'source': 'survey',
        },
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.uploaded,
      );

      const existingOnOsm = NearbyOsmElement(
        type: 'node',
        id: 11223344,
        version: 2,
        latitude: 35.68120,
        longitude: 139.76710,
        tags: {
          'amenity': 'cafe',
          'name': 'My Cafe',
          'opening_hours': '09:00-18:00',
          'day_off': 'Wednesday',
          'source': 'Edge Mapper (Firebase AI)',
        },
      );

      final match = OsmDuplicateService.evaluatePoiMatch(
        localRecord,
        existingOnOsm,
      );
      expect(match, isNotNull);
      expect(match!.hasTagChanges, isTrue);
      // Modified opening_hours and legacy software-name source are surfaced as differing tags
      expect(
        match.differingTagsAvailable.map((d) => d.key),
        containsAll(['opening_hours', 'source']),
      );
      // Upstream-only deprecated `day_off` is surfaced so the user can remove it upstream
      expect(match.upstreamOnlyTags['day_off'], equals('Wednesday'));

      // Update opening_hours + source AND remove deprecated day_off upstream
      final update = OsmElementTagUpdate(
        elementType: 'node',
        elementId: existingOnOsm.id,
        version: existingOnOsm.version,
        latitude: existingOnOsm.latitude,
        longitude: existingOnOsm.longitude,
        existingTags: existingOnOsm.tags,
        selectedNewTags: const {
          'opening_hours': 'Mo,Tu,Th-Su 09:00-18:00',
          'source': 'survey',
        },
        removedTagKeys: const {'day_off'},
        sourceRecordId: localRecord.id,
      );

      expect(
        OsmPublishService.validateForPublish(tagUpdates: [update])
            .where((i) => i.isBlocking),
        isEmpty,
      );
      final xml = OsmPublishService.buildOsmChangeXml(
        changesetId: 888,
        tagUpdates: [update],
      );
      expect(xml, contains('<modify>'));
      expect(xml, contains('k="opening_hours" v="Mo,Tu,Th-Su 09:00-18:00"'));
      expect(xml, contains('k="source" v="survey"'));
      expect(xml, isNot(contains('day_off')));

      // Removing ONLY a tag upstream (without adding/modifying any other tags) is also valid
      final removeOnly = OsmElementTagUpdate(
        elementType: 'node',
        elementId: existingOnOsm.id,
        version: existingOnOsm.version,
        latitude: existingOnOsm.latitude,
        longitude: existingOnOsm.longitude,
        existingTags: existingOnOsm.tags,
        removedTagKeys: const {'day_off'},
      );
      expect(
        OsmPublishService.validateForPublish(tagUpdates: [removeOnly])
            .where((i) => i.isBlocking),
        isEmpty,
      );
      final removeOnlyXml = OsmPublishService.buildOsmChangeXml(
        changesetId: 889,
        tagUpdates: [removeOnly],
      );
      expect(removeOnlyXml, isNot(contains('day_off')));
      expect(removeOnlyXml, contains('k="amenity" v="cafe"'));

      // Guard: removing ALL tags from an upstream element is blocked
      final stripAll = OsmElementTagUpdate(
        elementType: 'node',
        elementId: existingOnOsm.id,
        version: existingOnOsm.version,
        latitude: existingOnOsm.latitude,
        longitude: existingOnOsm.longitude,
        existingTags: const {'amenity': 'cafe'},
        removedTagKeys: const {'amenity'},
      );
      expect(
        OsmPublishService.validateForPublish(tagUpdates: [stripAll])
            .where((i) => i.isBlocking),
        isNotEmpty,
      );
    });
  });

  group('External Ham Radio GPS Track Import (NMEA, APRS, GPX, KML, CSV)', () {
    test('parses NMEA-0183 RMC + GGA logs (Icom / Yaesu / Kenwood), validates checksums & merges altitude/HDOP', () {
      String withChecksum(String body) {
        var xor = 0;
        for (var i = 0; i < body.length; i++) {
          xor ^= body.codeUnitAt(i);
        }
        return '\$$body*${xor.toRadixString(16).toUpperCase().padLeft(2, '0')}';
      }

      final nmeaLog = [
        withChecksum('GPRMC,091500,A,3540.8700,N,13946.0300,E,0.5,90.0,231126,,,A'),
        withChecksum('GPGGA,091500,3540.8700,N,13946.0300,E,1,08,1.2,412.5,M,39.0,M,,'),
        // Void fix (status V) must be skipped
        withChecksum('GPRMC,091530,V,3540.9000,N,13946.0500,E,0.0,0.0,231126,,,N'),
        // Corrupted RF/serial checksum must be skipped
        r'$GPRMC,091600,A,3540.9500,N,13946.1000,E,1.2,45.0,231126,,,A*00',
        // Valid second fix 1 minute later
        withChecksum('GNRMC,091600,A,3540.9500,N,13946.1000,E,1.2,45.0,231126,,,A'),
        withChecksum('GNGGA,091600,3540.9500,N,13946.1000,E,1,09,0.9,435.0,M,39.0,M,,'),
      ].join('\n');

      final parsed = HamRadioGpsImportService.parse(
        nmeaLog,
        fileName: 'mt_takao_id52.nmea',
      );

      expect(parsed.format, equals(HamRadioGpsFormat.nmea0183));
      expect(parsed.suggestedName, equals('mt takao id52'));
      expect(parsed.points.length, equals(2));
      expect(parsed.skippedEntries, equals(2));
      expect(parsed.points.first.latitude, closeTo(35.681167, 0.0001));
      expect(parsed.points.first.longitude, closeTo(139.767167, 0.0001));
      expect(parsed.points.first.altitudeMeters, closeTo(412.5, 0.01));
      expect(parsed.points.first.accuracyMeters, closeTo(6.0, 0.01));
      expect(parsed.points.first.recordedAt, equals(DateTime.utc(2026, 11, 23, 9, 15, 0)));
      expect(parsed.points.last.altitudeMeters, closeTo(435.0, 0.01));
      expect(parsed.duration, equals(const Duration(minutes: 1)));
      expect(parsed.totalDistanceMeters, greaterThan(100));
    });

    test('parses APRS TNC2 uncompressed, Mic-E (Yaesu/Kenwood/Anytone), & filters by callsign', () {
      final aprsLog = [
        '2026-11-23T09:00:00Z JA1ABC-7>APRS,WIDE1-1:!3540.80N/13946.00E[Trailhead /A=001000',
        '2026-11-23T09:05:00Z JA1ABC-7>SUTPX7:`CJ!l!I[/"8m}Mt Takao Ridge',
        '2026-11-23T09:06:00Z JA1XYZ-9>APRS:@230906z3541.50N/13947.00E>Other station',
      ].join('\n');

      final allStations = HamRadioGpsImportService.parse(aprsLog);
      expect(allStations.format, equals(HamRadioGpsFormat.aprs));
      expect(allStations.callsigns, equals(['JA1ABC-7', 'JA1XYZ-9']));
      expect(allStations.points.length, equals(3));

      // Verify uncompressed APRS altitude conversion (1000 ft = 304.8 m)
      expect(allStations.points[0].altitudeMeters, closeTo(304.8, 0.1));

      // Verify Mic-E decoded coordinates & base-91 altitude (450 m)
      expect(allStations.points[1].latitude, closeTo(35.681167, 0.0002));
      expect(allStations.points[1].longitude, closeTo(139.7675, 0.0002));
      expect(allStations.points[1].altitudeMeters, closeTo(450.0, 0.1));

      // Filter strictly to JA1ABC-7
      final filtered = HamRadioGpsImportService.parse(
        aprsLog,
        callsignFilter: 'JA1ABC-7',
      );
      expect(filtered.points.length, equals(2));
      expect(filtered.points.every((p) => p.callsign == 'JA1ABC-7'), isTrue);
      expect(filtered.suggestedName, contains('JA1ABC-7'));
    });

    test('parses GPX, KML (gx:Track & LineString), and Anytone/aprs.fi CSV GPS logs', () {
      const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1">
  <trk>
    <name>SOTA Summit Hike</name>
    <trkseg>
      <trkpt lat="35.6251" lon="139.2437"><ele>599.0</ele><time>2026-11-23T08:00:00Z</time><hdop>1.0</hdop></trkpt>
      <trkpt lat="35.6265" lon="139.2450"><ele>620.5</ele><time>2026-11-23T08:10:00Z</time><hdop>1.2</hdop></trkpt>
    </trkseg>
  </trk>
</gpx>
''';
      final gpxRes = HamRadioGpsImportService.parse(gpx, fileName: 'sota.gpx');
      expect(gpxRes.format, equals(HamRadioGpsFormat.gpx));
      expect(gpxRes.suggestedName, equals('SOTA Summit Hike'));
      expect(gpxRes.points.length, equals(2));
      expect(gpxRes.minAltitudeMeters, closeTo(599.0, 0.01));
      expect(gpxRes.maxAltitudeMeters, closeTo(620.5, 0.01));

      const kml = '''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
  <Document>
    <name>POTA Park Stroll</name>
    <Placemark>
      <gx:Track>
        <when>2026-11-23T10:00:00Z</when>
        <when>2026-11-23T10:05:00Z</when>
        <gx:coord>139.7000 35.6700 40.0</gx:coord>
        <gx:coord>139.7020 35.6715 44.5</gx:coord>
      </gx:Track>
    </Placemark>
  </Document>
</kml>
''';
      final kmlRes = HamRadioGpsImportService.parse(kml, fileName: 'pota.kml');
      expect(kmlRes.format, equals(HamRadioGpsFormat.kml));
      expect(kmlRes.suggestedName, equals('POTA Park Stroll'));
      expect(kmlRes.points.length, equals(2));
      expect(kmlRes.points.last.latitude, closeTo(35.6715, 0.0001));
      expect(kmlRes.points.last.altitudeMeters, closeTo(44.5, 0.01));

      const csv = '''
callsign,timestamp,latitude,longitude,altitude
W1AW-7,2026-11-23 11:00:00Z,41.7148,-72.7272,38.0
W1AW-7,2026-11-23 11:00:05Z,41.7148,-72.7272,38.0
W1AW-7,2026-11-23 11:02:00Z,41.7160,-72.7255,42.5
''';
      final csvRes = HamRadioGpsImportService.parse(
        csv,
        fileName: 'anytone_878.csv',
      );
      expect(csvRes.format, equals(HamRadioGpsFormat.csv));
      expect(csvRes.callsigns, equals(['W1AW-7']));
      // Exact duplicate static row trimmed cleanly
      expect(csvRes.points.length, equals(2));
      expect(csvRes.removedDuplicates, equals(1));
    });
  });

  group('Environment Variables Config & Encrypted OS / Passkey Vault', () {
    test('exports sanitized vs full .env config and keeps Firebase options strictly env-driven', () {
      final sanitized = AppEnvConfig.buildDotEnvExport(
        firebaseProject: 'my-proj',
        firebaseWebKey: 'AIza-secret-web-key',
        attestGateUrl: 'https://attest.example.org',
        osmClient: 'osm-client-123',
        personalGeminiKey: 'AIza-secret-gemini',
        customKey: 'sk-secret-openai',
        syncSpace: 'private-sync-code',
        selectedGeminiModel: 'gemini-3.5-flash-lite',
        includeSecrets: false,
      );
      expect(sanitized, contains('FIREBASE_PROJECT_ID=my-proj'));
      expect(sanitized, contains('ATTEST_GATE_BASE_URL=https://attest.example.org'));
      expect(sanitized, contains('OSM_CLIENT_ID=osm-client-123'));
      expect(sanitized, contains('GEMINI_MODEL=gemini-3.5-flash-lite'));
      expect(sanitized, isNot(contains('AIza-secret-web-key')));
      expect(sanitized, isNot(contains('AIza-secret-gemini')));
      expect(sanitized, isNot(contains('sk-secret-openai')));
      expect(sanitized, isNot(contains('private-sync-code')));
      expect(AppEnvConfig.allEnvVarNames, contains('ATTEST_GATE_BASE_URL'));
      expect(AppEnvConfig.attestGateBaseUrl, isEmpty);

      final full = AppEnvConfig.buildDotEnvExport(
        firebaseProject: 'my-proj',
        firebaseWebKey: 'AIza-secret-web-key',
        personalGeminiKey: 'AIza-secret-gemini',
        customKey: 'sk-secret-openai',
        syncSpace: 'private-sync-code',
        includeSecrets: true,
      );
      expect(full, contains('FIREBASE_WEB_API_KEY=AIza-secret-web-key'));
      expect(full, contains('GEMINI_API_KEY=AIza-secret-gemini'));
      expect(full, contains('CUSTOM_AI_API_KEY=sk-secret-openai'));
      expect(full, contains('FIREBASE_SYNC_SPACE_ID=private-sync-code'));

      // DefaultFirebaseOptions matches compile-time env state (never hardcoded!)
      expect(
        DefaultFirebaseOptions.web.apiKey,
        equals(AppEnvConfig.firebaseWebApiKey),
      );
      expect(
        DefaultFirebaseOptions.android.apiKey,
        equals(AppEnvConfig.firebaseAndroidApiKey),
      );
    });

    test('encrypts login tokens & API keys in SecureVaultService, wipes RAM on Passkey lock, and restores on unlock', () async {
      final mockBackend = _FakePasskeyVaultBackend();
      final vault = SecureVaultService(backend: mockBackend);
      await vault.init();

      final prefs = UserPreferencesService(vault: vault);
      await prefs.init();

      // Store sensitive credentials -> persisted inside encrypted vault
      await prefs.setOsmAuthSession(
        accessToken: 'osm-oauth-secret-token-xyz',
        username: 'real_osm_user',
        userId: 777,
      );
      await prefs.setPersonalGeminiApiKey('AIza-my-personal-gemini-key');
      await prefs.setSyncSpaceId('my-secret-space');

      expect(prefs.isOsmAuthenticated, isTrue);
      expect(prefs.osmAccessToken, equals('osm-oauth-secret-token-xyz'));
      expect(prefs.personalGeminiApiKey, equals('AIza-my-personal-gemini-key'));
      expect(vault.getSecret('osm_access_token'), equals('osm-oauth-secret-token-xyz'));
      expect(vault.getSecret('personal_gemini_api_key'), equals('AIza-my-personal-gemini-key'));

      // Upgrade to WebAuthn Passkey PRF (Bitwarden / YubiKey) & lock
      await vault.enrollPasskey(label: 'YubiKey 5C / Bitwarden');
      expect(vault.mode, equals(VaultProtectionMode.passkeyPrf));
      expect(vault.isUnlocked, isTrue);

      await vault.lock();
      expect(vault.isLocked, isTrue);
      // All sensitive values MUST be wiped from RAM when locked
      expect(prefs.isVaultLocked, isTrue);
      expect(prefs.osmAccessToken, isEmpty);
      expect(prefs.personalGeminiApiKey, isEmpty);
      expect(prefs.syncSpaceId, isEmpty);
      expect(prefs.isOsmAuthenticated, isFalse);

      // Unlocking via Passkey restores every sensitive credential cleanly
      await vault.unlockWithPasskey();
      expect(vault.isLocked, isFalse);
      expect(prefs.osmAccessToken, equals('osm-oauth-secret-token-xyz'));
      expect(prefs.personalGeminiApiKey, equals('AIza-my-personal-gemini-key'));
      expect(prefs.syncSpaceId, equals('my-secret-space'));
      expect(prefs.isOsmAuthenticated, isTrue);

      // Passphrase mode rejects wrong password and unlocks with correct password
      await vault.enablePassphraseLock('correct-horse-battery');
      await vault.lock();
      expect(prefs.osmAccessToken, isEmpty);
      await expectLater(
        vault.unlockWithPassphrase('wrong-passphrase'),
        throwsException,
      );
      await vault.unlockWithPassphrase('correct-horse-battery');
      expect(prefs.osmAccessToken, equals('osm-oauth-secret-token-xyz'));
    });

    test('Private Sync Key (emk1-...) generates checksummed 256-bit tokens, recovers deterministically across devices, and supports Passkey / Fingerprint / Passphrase login', () async {
      // 1. Key generation, checksum validation, normalization & deterministic derivation
      final keyA = SyncKeyService.generateKey();
      final keyB = SyncKeyService.generateKey();
      expect(keyA, startsWith('emk1-'));
      expect(keyA, isNot(equals(keyB)));
      expect(SyncKeyService.isValidKey(keyA), isTrue);

      final credsA1 = SyncKeyService.deriveCredentials(keyA);
      // Case-insensitive + whitespace/hyphen-tolerant recovery on Device B
      final messyPaste = '  ${keyA.toLowerCase().replaceAll('-', ' ')}  ';
      final credsA2 = SyncKeyService.deriveCredentials(messyPaste);
      expect(credsA2.canonicalKey, equals(credsA1.canonicalKey));
      expect(credsA2.fingerprint, equals(credsA1.fingerprint));
      expect(credsA2.internalIdentity, equals(credsA1.internalIdentity));
      expect(credsA2.derivedSecret, equals(credsA1.derivedSecret));
      expect(credsA1.internalIdentity, endsWith('@key.edgemapper.invalid'));
      expect(credsA1.derivedSecret.length, greaterThanOrEqualTo(40));

      // Single-character typo MUST be caught by the 24-bit checksum
      final lastChar = keyA[keyA.length - 1];
      final tampered =
          '${keyA.substring(0, keyA.length - 1)}${lastChar == 'A' ? 'B' : 'A'}';
      expect(SyncKeyService.isValidKey(tampered), isFalse);
      expect(
        () => SyncKeyService.deriveCredentials(tampered),
        throwsA(isA<FormatException>()),
      );

      // 2. Passwordless FirebaseSyncService vault lifecycle (zero email/password):
      final prefs = UserPreferencesService();
      await prefs.init();

      String? activeUid;
      final fb = FirebaseSyncService(
        prefs: prefs,
        uidOverride: () => activeUid,
        projectIdOverride: () => 'test-edge-mapper',
        vaultAuthOverride: (creds, {required bool createNew}) async {
          activeUid = 'uid-${creds.vaultFingerprint}';
        },
        authSignOutOverride: () async {
          activeUid = null;
        },
      );

      expect(fb.isSignedIn, isFalse);
      expect(fb.isVaultUnlocked, isFalse);

      await fb.signOutAndLock(clearHardwareCache: true);
      expect(fb.isSignedIn, isFalse);
      expect(fb.isVaultUnlocked, isFalse);
    });

    test('PasswordManagerBridge dispatches sync key save & retrieve directly to native Credential Manager / Bitwarden without copying to clipboard', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('com.edgemapper.app/password_manager');
      final recordedCalls = <MethodCall>[];
      final key = SyncKeyService.generateKey();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        recordedCalls.add(call);
        if (call.method == 'saveSyncKey') {
          return <String, dynamic>{
            'prompted': true,
            'saved': true,
            'message': 'Saved directly to Bitwarden / Android Credential Manager.',
          };
        }
        if (call.method == 'retrieveSyncKey') {
          return key;
        }
        if (call.method == 'copySensitive') {
          return true;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final res = await PasswordManagerBridge.saveSyncKey(
        accountLabel: 'Edge Mapper Sync Key (ABCD-1234-EF56)',
        syncKey: key,
      );
      expect(res.promptedPasswordManager, isTrue);
      expect(res.savedDirectly, isTrue);
      expect(recordedCalls.length, equals(1));
      expect(recordedCalls.first.method, equals('saveSyncKey'));
      final args = Map<String, dynamic>.from(
        recordedCalls.first.arguments as Map,
      );
      expect(args['label'], equals('Edge Mapper Sync Key (ABCD-1234-EF56)'));
      expect(args['syncKey'], equals(key));
      expect(args.containsKey('copyToClipboard'), isFalse);

      final retrieved = await PasswordManagerBridge.retrieveSavedSyncKey();
      expect(retrieved, equals(key));
      expect(recordedCalls.last.method, equals('retrieveSyncKey'));

      final copied = await PasswordManagerBridge.copySecretToClipboard(key);
      expect(copied, isTrue);
      expect(recordedCalls.last.method, equals('copySensitive'));
    });

    test('E2eeCryptoService matches NIST SP 800-38D AES-256-GCM vector and rejects wrong key, tampered ciphertext, or swapped AAD', () async {
      Uint8List hexToBytes(String hex) {
        final out = Uint8List(hex.length ~/ 2);
        for (int i = 0; i < out.length; i++) {
          out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
        }
        return out;
      }

      String bytesToHex(Uint8List bytes) =>
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      // Official NIST SP 800-38D AES-256-GCM Test Case 14 (all-zero 256-bit key, 96-bit IV, 128-bit PT, empty AAD)
      final zeroKey = Uint8List(32);
      final zeroIv = Uint8List(12);
      final zeroPt = Uint8List(16);
      final ctAndTag = E2eeCryptoService.encryptAes256GcmPureDart(
        key: zeroKey,
        iv: zeroIv,
        plaintext: zeroPt,
        aad: Uint8List(0),
      );
      expect(
        bytesToHex(Uint8List.sublistView(ctAndTag, 0, 16)),
        equals('cea7403d4d606b6e074ec5d3baf39d18'),
      );
      expect(
        bytesToHex(Uint8List.sublistView(ctAndTag, 16, 32)),
        equals('d0d1c8a799996bf0265b98b5d48ab919'),
      );
      final decZero = E2eeCryptoService.decryptAes256GcmPureDart(
        key: zeroKey,
        iv: zeroIv,
        ciphertextWithTag: ctAndTag,
        aad: Uint8List(0),
      );
      expect(decZero, equals(zeroPt));

      // Official NIST SP 800-38D AES-256-GCM Test Case 16 (with non-empty AAD)
      final key16 = hexToBytes(
        'feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308',
      );
      final iv16 = hexToBytes('cafebabefacedbaddecaf888');
      final pt16 = hexToBytes(
        'd9313225f88406e5a55909c5aff5269a'
        '86a7a9531534f7da2e4c303d8a318a72'
        '1c3c0c95956809532fcf0e2449a6b525'
        'b16aedf5aa0de657ba637b39',
      );
      final aad16 = hexToBytes('feedfacedeadbeeffeedfacedeadbeefabaddad2');
      final ct16AndTag = E2eeCryptoService.encryptAes256GcmPureDart(
        key: key16,
        iv: iv16,
        plaintext: pt16,
        aad: aad16,
      );
      expect(
        bytesToHex(Uint8List.sublistView(ct16AndTag, 0, pt16.length)),
        equals(
          '522dc1f099567d07f47f37a32a84427d'
          '643a8cdcbfe5c0c97598a2bd2555d1aa'
          '8cb08e48590dbb3da7b08b1056828838'
          'c5f61e6393ba7a0abcc9f662',
        ),
      );
      expect(
        bytesToHex(Uint8List.sublistView(ct16AndTag, pt16.length)),
        equals('76fc6ece0f4e1768cddf8853bb2d551b'),
      );

      // SyncKey-derived E2EE round-trip + tamper/wrong-key/AAD rejection
      final keyA = SyncKeyService.generateKey();
      final keyB = SyncKeyService.generateKey();
      final dataKeyA = SyncKeyService.deriveDataEncryptionKey(keyA);
      final dataKeyB = SyncKeyService.deriveDataEncryptionKey(keyB);
      final enc = await E2eeCryptoService.encryptString(
        key: dataKeyA,
        plaintext: '{"name":"Secret Shrine","lat":35.6251}',
        aad: 'em-e2ee:v1:record-meta:uid-1:rec-1',
      );
      final dec = await E2eeCryptoService.decryptString(
        key: dataKeyA,
        ivB64: enc.ivB64,
        ciphertextB64: enc.ciphertextB64,
        aad: 'em-e2ee:v1:record-meta:uid-1:rec-1',
      );
      expect(dec, equals('{"name":"Secret Shrine","lat":35.6251}'));

      // Wrong Sync Key MUST fail decryption
      await expectLater(
        () => E2eeCryptoService.decryptString(
          key: dataKeyB,
          ivB64: enc.ivB64,
          ciphertextB64: enc.ciphertextB64,
          aad: 'em-e2ee:v1:record-meta:uid-1:rec-1',
        ),
        throwsA(isA<E2eeDecryptionException>()),
      );

      // Swapped AAD (e.g. moving doc between users/docIds) MUST fail GCM auth tag
      await expectLater(
        () => E2eeCryptoService.decryptString(
          key: dataKeyA,
          ivB64: enc.ivB64,
          ciphertextB64: enc.ciphertextB64,
          aad: 'em-e2ee:v1:record-meta:uid-2:rec-1',
        ),
        throwsA(isA<E2eeDecryptionException>()),
      );

      // Flipping 1 bit of ciphertext MUST fail GCM auth tag
      final rawCt = Uint8List.fromList(base64Decode(enc.ciphertextB64));
      rawCt[0] ^= 0x01;
      await expectLater(
        () => E2eeCryptoService.decryptString(
          key: dataKeyA,
          ivB64: enc.ivB64,
          ciphertextB64: base64Encode(rawCt),
          aad: 'em-e2ee:v1:record-meta:uid-1:rec-1',
        ),
        throwsA(isA<E2eeDecryptionException>()),
      );
    });

    testWidgets('showAdaptiveSheet lifts modal content above soft keyboard viewInsets on phones', (tester) async {
      const phoneSize = Size(412, 915);
      const keyboardHeight = 340.0;

      await tester.binding.setSurfaceSize(phoneSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: phoneSize,
            viewInsets: EdgeInsets.only(bottom: keyboardHeight),
          ),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: ElevatedButton(
                    onPressed: () {
                      showAdaptiveSheet<void>(
                        context: ctx,
                        builder: (_) => AdaptiveModalScrollContainer(
                          builder: (_, ctrl) => SingleChildScrollView(
                            controller: ctrl,
                            child: const Column(
                              children: [
                                SizedBox(height: 120),
                                TextField(
                                  key: ValueKey('modal-input'),
                                  decoration: InputDecoration(
                                    labelText: 'OAuth Client ID',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('Open Modal'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Modal'));
      await tester.pumpAndSettle();

      final inputRect = tester.getRect(find.byKey(const ValueKey('modal-input')));
      final keyboardTop = phoneSize.height - keyboardHeight;
      // Input box MUST sit strictly above the soft keyboard!
      expect(inputRect.bottom, lessThanOrEqualTo(keyboardTop));
    });
  });

  group('Developer-Managed OSM OAuth 2.0 & Automatic Callback UX', () {
    test('uses edgemapper://oauth2/callback on Android/IO, validates state, and completes OAuth automatically', () async {
      expect(defaultOsmRedirectUri(), equals(OsmPublishService.androidRedirectUri));
      expect(supportsOAuthPopup, isTrue);

      // Callback URI parser accepts valid state, rejects CSRF state mismatch, surfaces error
      expect(
        OsmPublishService.parseOAuthCallbackUri(
          'edgemapper://oauth2/callback?code=auto_code_77&state=state_abc',
          expectedState: 'state_abc',
        ),
        equals('auto_code_77'),
      );
      expect(
        () => OsmPublishService.parseOAuthCallbackUri(
          'edgemapper://oauth2/callback?code=auto_code_77&state=wrong_state',
          expectedState: 'state_abc',
        ),
        throwsStateError,
      );
      expect(
        () => OsmPublishService.parseOAuthCallbackUri(
          'edgemapper://oauth2/callback?error=access_denied&error_description=User+denied&state=state_abc',
          expectedState: 'state_abc',
        ),
        throwsException,
      );

      final prefs = UserPreferencesService();
      String? seenAuthorizeUrl;
      String? seenTokenBody;

      final mockClient = MockClient((req) async {
        if (req.method == 'POST' && req.url.path == '/oauth2/token') {
          seenTokenBody = req.body;
          return http.Response(
            jsonEncode({'access_token': 'osm_auto_token_123', 'token_type': 'Bearer'}),
            200,
          );
        }
        if (req.method == 'GET' && req.url.path == '/api/0.6/user/details.json') {
          expect(req.headers['Authorization'], equals('Bearer osm_auto_token_123'));
          return http.Response(
            jsonEncode({
              'user': {
                'id': 4242,
                'display_name': 'FieldExplorer',
                'changesets': {'count': 19},
              },
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final osm = OsmPublishService(
        prefs: prefs,
        client: mockClient,
        liveClientIdOverride: 'dev_live_client_id_xyz',
        sandboxClientIdOverride: 'dev_sandbox_client_id_999',
        oauthLauncher: ({
          required String authorizeUrl,
          required String expectedState,
        }) async {
          seenAuthorizeUrl = authorizeUrl;
          final callbackUrl =
              'edgemapper://oauth2/callback?code=pkce_auto_code&state=$expectedState';
          return OsmPublishService.parseOAuthCallbackUri(
            callbackUrl,
            expectedState: expectedState,
          );
        },
      );

      expect(osm.isOAuthConfigured, isTrue);
      expect(osm.effectiveClientId, equals('dev_live_client_id_xyz'));
      expect(osm.effectiveRedirectUri, equals('edgemapper://oauth2/callback'));

      final profile = await osm.beginInteractiveOAuth();
      expect(profile, isNotNull);
      expect(profile!.displayName, equals('FieldExplorer'));
      expect(osm.isAuthenticated, isTrue);
      expect(osm.username, equals('FieldExplorer'));
      expect(seenAuthorizeUrl, contains('client_id=dev_live_client_id_xyz'));
      expect(
        seenAuthorizeUrl,
        contains(Uri.encodeQueryComponent('edgemapper://oauth2/callback')),
      );
      expect(seenTokenBody, contains('client_id=dev_live_client_id_xyz'));
      expect(seenTokenBody, contains('code=pkce_auto_code'));

      // Switching to Sandbox selects sandbox developer client ID
      await prefs.setOsmUseSandbox(true);
      expect(osm.effectiveClientId, equals('dev_sandbox_client_id_999'));
    });

    testWidgets('OsmAuthSheet hides Client ID, Redirect URI, and manual code paste from end users', (tester) async {
      final prefs = UserPreferencesService();
      final mockClient = MockClient((req) async {
        if (req.method == 'POST' && req.url.path == '/oauth2/token') {
          return http.Response(
            jsonEncode({'access_token': 'osm_token_widget_test'}),
            200,
          );
        }
        if (req.method == 'GET' && req.url.path == '/api/0.6/user/details.json') {
          return http.Response(
            jsonEncode({
              'user': {
                'id': 9001,
                'display_name': 'TrailMapper',
                'changesets': {'count': 7},
              },
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final osm = OsmPublishService(
        prefs: prefs,
        client: mockClient,
        liveClientIdOverride: 'dev_built_in_client_id',
        oauthLauncher: ({
          required String authorizeUrl,
          required String expectedState,
        }) async =>
            'instant_callback_code',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OsmAuthSheet(osm: osm, prefs: prefs),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Developer OAuth setup & manual copy-paste inputs MUST NOT appear to end users
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('Client ID'), findsNothing);
      expect(find.textContaining('Redirect URI'), findsNothing);
      expect(find.textContaining('Create OSM App'), findsNothing);
      expect(find.textContaining('Authorization Code'), findsNothing);
      expect(find.textContaining('Access Token'), findsNothing);

      // One-tap Sign in with OpenStreetMap signs in automatically!
      final signInButton = find.text('Sign in with OpenStreetMap');
      expect(signInButton, findsOneWidget);
      await tester.tap(signInButton);
      await tester.pumpAndSettle();

      expect(osm.isAuthenticated, isTrue);
      expect(find.text('TrailMapper'), findsOneWidget);
      expect(find.textContaining('Signed in as TrailMapper'), findsOneWidget);
    });
  });

  group('Anti-Hallucination Real OpenStreetMap Tag Guard & Taginfo Verifier', () {
    test('repairs fitness_equipment=monkey_bars to fitness_station=horizontal_ladder and drops invented non-OSM keys', () {
      // Simulate AI JSON that hallucinated fitness_equipment=monkey_bars and totally fake keys
      final rawAiJson = jsonEncode({
        'summary': 'A monkey bar set in a public park',
        'detectedLanguage': 'en',
        'osmType': 'node',
        'estimatedOffsetMeters': 5.0,
        'tags': [
          {'key': 'leisure', 'value': 'fitness_station'},
          {'key': 'fitness_equipment', 'value': 'monkey_bars'},
          {'key': 'color', 'value': 'green'},
          {'key': 'park_vibe', 'value': 'relaxing'},
          {'key': 'made_up_tag_xyz', 'value': 'foobar'},
          {'key': 'name:en', 'value': 'Central Park Fitness'},
          {'key': 'payment:suica', 'value': 'yes'},
        ],
        'tagCandidates': [
          {'key': 'fitness_equipment', 'value': 'pull_up_bars', 'probability': 0.85},
          {'key': 'playground_equipment', 'value': 'climbing_frame', 'probability': 0.72},
          {'key': 'totally_fake_key', 'value': '123', 'probability': 0.90},
        ],
      });

      final parsed = HybridAiService.parseStructuredOsmJson(
        rawAiJson,
        aiSource: AiSource.personalGeminiApi,
        hasGpsFix: true,
      );

      // Fake key MUST NOT exist; replaced by real OSM Wiki tag!
      expect(parsed.tags.containsKey('fitness_equipment'), isFalse);
      expect(parsed.tags['leisure'], equals('fitness_station'));
      expect(parsed.tags['fitness_station'], equals('horizontal_ladder'));
      expect(parsed.tags['colour'], equals('green'));
      expect(parsed.tags.containsKey('color'), isFalse);
      expect(parsed.tags['name:en'], equals('Central Park Fitness'));
      expect(parsed.tags['payment:suica'], equals('yes'));

      // Completely fabricated keys MUST be dropped
      expect(parsed.tags.containsKey('park_vibe'), isFalse);
      expect(parsed.tags.containsKey('made_up_tag_xyz'), isFalse);

      // Candidates are also repaired & stripped of fake keys
      expect(parsed.tagCandidates.containsKey('fitness_station=horizontal_bar'), isTrue);
      expect(parsed.tagCandidates.containsKey('playground=climbingframe'), isTrue);
      expect(parsed.tagCandidates.keys.any((k) => k.startsWith('totally_fake_key=')), isFalse);
      expect(parsed.tagCandidates.keys.any((k) => k.startsWith('fitness_equipment=')), isFalse);

      // Existing saved records containing fitness_equipment=monkey_bars are flagged with 1-tap Auto-Fix
      final notices = OsmTagStandards.findDeprecatedTags(const {
        'leisure': 'fitness_station',
        'fitness_equipment': 'monkey_bars',
        'nonexistent_key': 'mystery',
      });
      final fitNotice = notices.firstWhere((n) => n.key == 'fitness_equipment');
      expect(fitNotice.canAutoFix, isTrue);
      expect(fitNotice.replacementSummary, equals('fitness_station=horizontal_ladder'));
      expect(notices.any((n) => n.key == 'nonexistent_key'), isTrue);
    });

    test('OsmTagVerifierService drops fabricated values on primary OSM keys via live Taginfo API', () async {
      final queriedPairs = <String>[];
      final mockTaginfo = MockClient((req) async {
        expect(req.url.host, equals('taginfo.openstreetmap.org'));
        final k = req.url.queryParameters['key'] ?? '';
        final v = req.url.queryParameters['value'] ?? '';
        queriedPairs.add('$k=$v');

        // Real documented OSM tag (not in local catalog yet): leisure=disc_golf_course
        if (k == 'leisure' && v == 'disc_golf_course') {
          return http.Response(
            jsonEncode({
              'data': {
                'in_wiki': true,
                'counts': [
                  {'type': 'all', 'count': 4200},
                ],
              },
            }),
            200,
          );
        }
        // Hallucinated non-existent value on a real key: leisure=monkey_gym_zone
        return http.Response(
          jsonEncode({
            'data': {
              'in_wiki': false,
              'counts': [
                {'type': 'all', 'count': 0},
              ],
            },
          }),
          200,
        );
      });

      final verifier = OsmTagVerifierService(client: mockTaginfo);
      final res = await verifier.verifyAiTags(
        const {
          'leisure': 'monkey_gym_zone', // fake value on real key!
          'amenity': 'bench', // already verified offline in catalog (no Taginfo call needed)
          'fitness_equipment': 'monkey_bars', // repaired to fitness_station=horizontal_ladder
          'made_up_key': 'anything', // dropped offline
        },
        isOnline: true,
      );

      expect(res.verifiedTags.containsKey('leisure'), isFalse);
      expect(res.droppedTags, contains('leisure=monkey_gym_zone'));
      expect(res.verifiedTags['amenity'], equals('bench'));
      expect(res.verifiedTags['fitness_station'], equals('horizontal_ladder'));
      expect(res.verifiedTags.containsKey('made_up_key'), isFalse);
      expect(queriedPairs, equals(['leisure=monkey_gym_zone']));

      // Real OSM tag confirmed by Taginfo passes!
      final realRes = await verifier.verifyAiTags(
        const {'leisure': 'disc_golf_course'},
        isOnline: true,
      );
      expect(realRes.verifiedTags['leisure'], equals('disc_golf_course'));
      expect(realRes.droppedTags, isEmpty);
    });

    test('anti-hallucination hardening strips placeholders, fixes strict OSM vocabularies, rejects partial semicolon hallucinations, and catches invalid tags before publish', () async {
      // 1. Offline sanitization drops placeholders, prose opening_hours, and fabricated strict values,
      //    and repairs common LLM synonyms + invalid source=GPS
      final sanitized = OsmTagStandards.sanitizeAiTags(const {
        'amenity': 'cafe',
        'name': 'N/A', // placeholder hallucination -> dropped
        'phone': 'unknown', // placeholder hallucination -> dropped
        'brand': 'none', // disallowed none -> dropped
        'source': 'survey;GPS', // invalid GPS -> survey
        'access': 'public', // alias -> yes
        'wheelchair': 'accessible', // alias -> yes
        'fee': 'free', // alias -> no
        'smoking': 'prohibited', // alias -> no
        'internet_access': 'free_wifi', // alias -> wlan + internet_access:fee=no
        'parking': 'lot', // alias -> surface
        'lit': 'unlit', // alias -> no
        'smoothness': 'quantum_smooth', // fabricated closed-vocab value -> dropped
        'opening_hours': 'Open daily except holidays', // prose hallucination -> dropped
      });

      expect(sanitized.containsKey('name'), isFalse);
      expect(sanitized.containsKey('phone'), isFalse);
      expect(sanitized.containsKey('brand'), isFalse);
      expect(sanitized['source'], equals('survey'));
      expect(sanitized['access'], equals('yes'));
      expect(sanitized['wheelchair'], equals('yes'));
      expect(sanitized['fee'], equals('no'));
      expect(sanitized['smoking'], equals('no'));
      expect(sanitized['internet_access'], equals('wlan'));
      expect(sanitized['internet_access:fee'], equals('no'));
      expect(sanitized['parking'], equals('surface'));
      expect(sanitized['lit'], equals('no'));
      expect(sanitized.containsKey('smoothness'), isFalse);
      expect(sanitized.containsKey('opening_hours'), isFalse);

      // 2. Unfixable invalid tags block OsmPublishService.validateForPublish
      final badRecord = OsmRecord(
        id: 'bad-hallucinated',
        createdAt: DateTime.utc(2026, 11, 25),
        latitude: 35.6812,
        longitude: 139.7671,
        summary: 'Test',
        tags: const {
          'amenity': 'cafe',
          'wheelchair': 'banana',
          'totally_fake_key': 'xyz',
        },
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.readyToUpload,
      );
      final publishIssues = OsmPublishService.validateForPublish(records: [badRecord]);
      expect(
        publishIssues.where((i) => i.isBlocking).length,
        greaterThanOrEqualTo(2),
      );

      // 3. Taginfo verifier requires ALL semicolon tokens to be valid AND verifies controlled secondary keys
      final mockTaginfo = MockClient((req) async {
        final k = req.url.queryParameters['key'] ?? '';
        final v = req.url.queryParameters['value'] ?? '';
        if (k == 'cuisine' && v == 'ramen') {
          return http.Response(
            jsonEncode({
              'data': {
                'in_wiki': true,
                'counts': [
                  {'type': 'all', 'count': 9000},
                ],
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'data': {
              'in_wiki': false,
              'counts': [
                {'type': 'all', 'count': 0},
              ],
            },
          }),
          200,
        );
      });

      final verifier = OsmTagVerifierService(client: mockTaginfo);
      final aiRes = await verifier.verifyAiTags(
        const {
          'amenity': 'restaurant',
          'cuisine': 'ramen;hallucinated_noodle_xyz',
          'material': 'quantum_titanium',
        },
        isOnline: true,
      );
      expect(aiRes.verifiedTags.containsKey('cuisine'), isFalse);
      expect(aiRes.verifiedTags.containsKey('material'), isFalse);
      expect(
        aiRes.droppedTags,
        containsAll(['cuisine=ramen;hallucinated_noodle_xyz', 'material=quantum_titanium']),
      );

      // 4. Pre-publish verifyTagsForPublish flags Taginfo-rejected tags as confirmedInvalid
      final report = await verifier.verifyTagsForPublish(
        items: const [
          (
            id: 'rec-1',
            label: 'Ramen Spot',
            tags: {
              'amenity': 'restaurant',
              'material': 'quantum_titanium',
              'source': 'survey;GPS', // auto-modernized to survey -> clean!
            },
          ),
        ],
        isOnline: true,
      );
      expect(report.hasConfirmedInvalid, isTrue);
      expect(report.confirmedInvalid.single.key, equals('material'));
      expect(report.confirmedInvalid.single.value, equals('quantum_titanium'));
    });
  });
}

class _FakePasskeyVaultBackend implements SecureVaultBackend {
  final Map<String, String> _encryptedBlob = {};
  VaultProtectionMode _mode = VaultProtectionMode.osKeystore;
  bool _locked = false;
  String _label = '';
  String? _passphrase;

  @override
  Future<VaultStatusInfo> getStatus() async => VaultStatusInfo(
        mode: _mode,
        isLocked: _locked,
        hasStoredSecrets: _encryptedBlob.isNotEmpty,
        supportsPasskeyPrf: true,
        supportsOsBiometric: true,
        credentialLabel: _label,
        detail: _mode.displayLabel,
      );

  @override
  Future<VaultReadResult> readAllSecrets() async => VaultReadResult(
        locked: _locked,
        secrets: _locked ? const {} : Map<String, String>.from(_encryptedBlob),
      );

  @override
  Future<void> writeAllSecrets(Map<String, String> secrets) async {
    if (_locked) throw StateError('Locked');
    _encryptedBlob
      ..clear()
      ..addAll(secrets);
  }

  @override
  Future<void> enrollPasskey({required String label}) async {
    _mode = VaultProtectionMode.passkeyPrf;
    _label = label;
    _locked = false;
  }

  @override
  Future<Map<String, String>> unlockWithPasskey() async {
    _locked = false;
    return Map<String, String>.from(_encryptedBlob);
  }

  @override
  Future<void> enableOsBiometricLock() async {
    _mode = VaultProtectionMode.osBiometric;
    _locked = false;
  }

  @override
  Future<Map<String, String>> unlockWithOsBiometric() async {
    _locked = false;
    return Map<String, String>.from(_encryptedBlob);
  }

  @override
  Future<void> enablePassphrase(String passphrase) async {
    _mode = VaultProtectionMode.passphrase;
    _passphrase = passphrase;
    _locked = false;
  }

  @override
  Future<Map<String, String>> unlockWithPassphrase(String passphrase) async {
    if (passphrase != _passphrase) {
      throw Exception('Incorrect vault passphrase.');
    }
    _locked = false;
    return Map<String, String>.from(_encryptedBlob);
  }

  @override
  Future<void> switchToOsKeystore() async {
    _mode = VaultProtectionMode.osKeystore;
    _passphrase = null;
    _locked = false;
  }

  @override
  Future<void> lock() async {
    if (_mode.requiresExplicitUnlock) {
      _locked = true;
    }
  }
}
