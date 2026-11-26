import 'dart:typed_data';

import 'package:edge_mapper/models/hike_trail.dart';
import 'package:edge_mapper/models/mapping_bounty.dart';
import 'package:edge_mapper/models/osm_record.dart';
import 'package:edge_mapper/screens/capture_screen.dart';
import 'package:edge_mapper/screens/community_screen.dart';
import 'package:edge_mapper/screens/home_shell.dart';
import 'package:edge_mapper/screens/record_detail_screen.dart';
import 'package:edge_mapper/screens/records_screen.dart';
import 'package:edge_mapper/screens/trail_detail_screen.dart';
import 'package:edge_mapper/screens/trail_screen.dart';
import 'package:edge_mapper/services/bitcoin_service.dart';
import 'package:edge_mapper/services/bounty_service.dart';
import 'package:edge_mapper/services/connectivity_service.dart';
import 'package:edge_mapper/services/e2ee_envelope_crypto.dart';
import 'package:edge_mapper/services/e2ee_platform_bridge.dart';
import 'package:edge_mapper/services/firebase_sync_service.dart';
import 'package:edge_mapper/services/hybrid_ai_service.dart';
import 'package:edge_mapper/services/leaderboard_service.dart';
import 'package:edge_mapper/services/local_db_service.dart';
import 'package:edge_mapper/services/location_context_service.dart';
import 'package:edge_mapper/services/mapper_store.dart';
import 'package:edge_mapper/services/offline_tile_service.dart';
import 'package:edge_mapper/services/osm_duplicate_service.dart';
import 'package:edge_mapper/services/osm_publish_service.dart';
import 'package:edge_mapper/services/osm_tag_verifier_service.dart';
import 'package:edge_mapper/services/sensor_service.dart';
import 'package:edge_mapper/services/user_preferences_service.dart';
import 'package:edge_mapper/theme/app_theme.dart';
import 'package:edge_mapper/widgets/ai_status_sheet.dart';
import 'package:edge_mapper/widgets/bitcoin_donate_sheet.dart';
import 'package:edge_mapper/widgets/compass_badge.dart';
import 'package:edge_mapper/widgets/firebase_auth_sheet.dart';
import 'package:edge_mapper/widgets/fine_pin_position_pad.dart';
import 'package:edge_mapper/widgets/gps_warning_banner.dart';
import 'package:edge_mapper/widgets/mapper_quest_bar.dart';
import 'package:edge_mapper/widgets/osm_map_widget.dart';
import 'package:edge_mapper/widgets/osm_publish_sheet.dart';
import 'package:edge_mapper/widgets/qr_code_widget.dart';
import 'package:edge_mapper/widgets/responsive_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _InMemoryLocalDbService extends LocalDbService {
  final Map<String, OsmRecord> _records = {};
  final Map<String, HikeTrail> _trails = {};
  final Map<String, String> _settings = {};

  @override
  Future<void> upsertRecord(OsmRecord record) async {
    _records[record.id] = record;
  }

  @override
  Future<List<OsmRecord>> getAllRecords() async => _records.values.toList();

  @override
  Future<void> deleteRecord(String id) async {
    _records.remove(id);
  }

  @override
  Future<void> upsertTrail(HikeTrail trail) async {
    _trails[trail.id] = trail;
  }

  @override
  Future<void> deleteTrail(String trailId) async {
    _trails.remove(trailId);
  }

  @override
  Future<List<HikeTrail>> getAllTrails() async => _trails.values.toList();

  @override
  Future<List<MappingBounty>> getAllBounties() async => const [];

  @override
  Future<Map<String, String>> getAllSettings() async =>
      Map<String, String>.from(_settings);

  @override
  Future<void> setSetting(String key, String value) async {
    _settings[key] = value;
  }
}

class _TestHarness {
  final LocalDbService db = _InMemoryLocalDbService();
  final UserPreferencesService prefs = UserPreferencesService();
  final ConnectivityService connectivity;

  _TestHarness({bool initialOnline = false})
      : connectivity = ConnectivityService(initialHasNetwork: initialOnline);
  final OfflineTileService tiles = OfflineTileService();
  final SensorService sensors = SensorService();
  late final HybridAiService ai =
      HybridAiService(connectivity: connectivity, prefs: prefs);
  late final FirebaseSyncService firebaseSync =
      FirebaseSyncService(prefs: prefs);
  late final OsmPublishService osmPublish = OsmPublishService(prefs: prefs);
  late final LeaderboardService leaderboard = LeaderboardService(
    prefs: prefs,
    firebaseSync: firebaseSync,
    connectivity: connectivity,
  );
  late final BountyService bounties = BountyService(
    db: db,
    prefs: prefs,
    firebaseSync: firebaseSync,
    connectivity: connectivity,
  );
  late final MapperStore store = MapperStore(
    db: db,
    sensors: sensors,
    ai: ai,
    connectivity: connectivity,
    prefs: prefs,
    firebaseSync: firebaseSync,
    tiles: tiles,
  );

  Widget buildApp({
    ThemeData? theme,
    double textScale = 1.0,
    Widget? home,
  }) {
    return MaterialApp(
      theme: theme ?? AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: home ??
          HomeShell(
            connectivity: connectivity,
            sensors: sensors,
            ai: ai,
            store: store,
            prefs: prefs,
            firebaseSync: firebaseSync,
            tiles: tiles,
            osmPublish: osmPublish,
            leaderboard: leaderboard,
            bounties: bounties,
          ),
    );
  }
}

void main() {
  group('Material 3 Design System & Semantic Tokens', () {
    test('provides contrast-adapted semantic colors and M3 component themes in Light & Dark modes', () {
      final light = AppTheme.light();
      final dark = AppTheme.dark();

      expect(light.useMaterial3, isTrue);
      expect(dark.useMaterial3, isTrue);
      expect(light.snackBarTheme.behavior, equals(SnackBarBehavior.floating));
      expect(
        light.navigationBarTheme.labelBehavior,
        equals(NavigationDestinationLabelBehavior.alwaysShow),
      );

      final lightSem = light.extension<AppSemanticColors>()!;
      final darkSem = dark.extension<AppSemanticColors>()!;

      // Semantic colors adapt luminance for dark backgrounds
      expect(lightSem.success, isNot(equals(darkSem.success)));
      expect(lightSem.warning, isNot(equals(darkSem.warning)));
      expect(lightSem.danger, isNot(equals(darkSem.danger)));
      expect(lightSem.warningContainer, isNot(equals(darkSem.warningContainer)));

      // Clear typographic hierarchy
      expect(
        light.textTheme.headlineSmall!.fontSize!,
        greaterThan(light.textTheme.titleMedium!.fontSize!),
      );
      expect(
        light.textTheme.titleMedium!.fontSize!,
        greaterThan(light.textTheme.bodyMedium!.fontSize!),
      );
      expect(
        light.textTheme.bodyMedium!.fontSize!,
        greaterThan(light.textTheme.bodySmall!.fontSize!),
      );
    });
  });

  group('Responsive Navigation & Overflow-Free Layouts Across Screen Sizes', () {
    testWidgets('Compact smartphone (360x780) uses bottom NavigationBar and switches tabs cleanly under 1.35x text scale', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _TestHarness(initialOnline: true);
      await tester.pumpWidget(h.buildApp(textScale: 1.35));
      await tester.pumpAndSettle();

      // Bottom NavigationBar is present on compact phones
      expect(find.byType(NavigationBar), findsOneWidget);
      // Primary Capture actions live in a thumb-friendly BottomActionDock
      expect(find.byType(BottomActionDock), findsOneWidget);
      final takePhotoCenter = tester.getCenter(find.text('Take Photo'));
      expect(takePhotoCenter.dy, greaterThan(500));
      // Minimized input: Quick Category is removed and optional hint TextField stays hidden until tapped
      // expect(find.text('Quick Category'), findsNothing);
      // expect(find.byType(TextField), findsNothing);
      // await tester.ensureVisible(find.text('Add hint'));
      // await tester.pumpAndSettle();
      // await tester.tap(find.text('Add hint'));
      // await tester.pumpAndSettle();
      // expect(find.byType(TextField), findsOneWidget);

      // Navigate across all 4 tabs and verify context-aware AppBar & zero layout exceptions
      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Routes'),
      ));
      await tester.pumpAndSettle();
      expect(find.text('New Route'), findsOneWidget);
      // Minimized input: route name auto-named with zero upfront TextField
      expect(find.text('More tags'), findsOneWidget);
      expect(find.textContaining('Auto-named'), findsOneWidget);
      expect(find.byType(BottomActionDock), findsWidgets);

      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Records'),
      ));
      await tester.pumpAndSettle();
      expect(find.text('No records yet'), findsOneWidget);
      // Intuitive next-step CTA guides empty state back to Capture
      expect(find.text('Capture Place'), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Guild'),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Explorer Guild'), findsOneWidget);
      expect(find.text('Real OpenStreetMap Mappers Near POI'), findsOneWidget);
      expect(find.textContaining('Bounties'), findsNothing);
      expect(find.text('Hero'), findsNothing);

      expect(tester.takeException(), isNull);
    });

    testWidgets('Medium tablet (768x1024) uses labeled vertical rail instead of bottom NavigationBar', (tester) async {
      tester.view.physicalSize = const Size(768, 1024);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _TestHarness(initialOnline: true);
      await tester.pumpWidget(h.buildApp(theme: AppTheme.dark()));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsNothing);
      // Tablet rail shows explicit visible labels for touch clarity
      expect(find.text('Capture'), findsOneWidget);
      expect(find.text('Routes'), findsOneWidget);
      expect(find.text('Records'), findsOneWidget);
      expect(find.text('Guild'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Expanded desktop (1280x800) uses extended sidebar with split workspace', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _TestHarness(initialOnline: true);
      await tester.pumpWidget(h.buildApp());
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Explorer Guild'), findsOneWidget);
      expect(find.text('Capture Place'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Minimalistic Settings Sheet & Shared UI Primitives', () {
    testWidgets('AiStatusSheet organizes advanced settings into scannable collapsible groups', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _TestHarness(initialOnline: true);
      await tester.pumpWidget(
        h.buildApp(
          home: Scaffold(
            body: AiStatusSheet(
              connectivity: h.connectivity,
              ai: h.ai,
              prefs: h.prefs,
              firebaseSync: h.firebaseSync,
              tiles: h.tiles,
              osmPublish: h.osmPublish,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Core essentials visible immediately
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Offline Mode'), findsOneWidget);
      expect(find.text('OpenStreetMap Account'), findsOneWidget);

      // Grouped collapsible categories keep the default view uncluttered
      expect(find.text('Languages'), findsOneWidget);
      expect(find.text('AI Engine & Models'), findsOneWidget);
      expect(find.text('Cloud Backup & Sync'), findsOneWidget);
      // Removed unneeded settings sections; warm Support button replaces Explorer Profile & Support
      expect(find.text('Security Vault & .env'), findsNothing);
      expect(find.text('Explorer Profile & Support'), findsNothing);
      expect(find.text('Explorer Display Name'), findsNothing);
      expect(find.text('Donate Bitcoin'), findsNothing);
      expect(find.text('Support Edge Mapper'), findsOneWidget);

      // Expanding Cloud Backup & Sync shows Zero-Knowledge E2EE Sync without
      // Manual Firebase Project Override or Backup reminders
      await tester.tap(find.text('Cloud Backup & Sync'));
      await tester.pumpAndSettle();
      expect(find.text('Zero-Knowledge E2EE Cloud Sync'), findsOneWidget);
      expect(find.text('Manual Firebase Project Override'), findsNothing);
      expect(find.text('Backup reminders'), findsNothing);

      // Advanced inputs stay tucked away until expanded
      expect(find.text('Custom Gemini Model ID'), findsNothing);
      await tester.tap(find.text('AI Engine & Models'));
      await tester.pumpAndSettle();
      expect(find.text('Custom Gemini Model ID'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('InlineNoticeBanner & EmptyStateCard render cleanly in Dark mode', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Column(
              children: [
                InlineNoticeBanner(
                  tone: NoticeTone.warning,
                  icon: Icons.gps_not_fixed_rounded,
                  title: 'Weak GPS Signal',
                  detail: 'Move to an open area for better accuracy.',
                ),
                EmptyStateCard(
                  icon: Icons.layers_outlined,
                  title: 'No records yet',
                  description: 'Capture a place to see it listed here.',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Weak GPS Signal'), findsOneWidget);
      expect(find.text('No records yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('RecordDetailScreen removes Summary/noise, uses 2D FinePinPositionPad, and auto-saves pin moves', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _TestHarness();
      final record = OsmRecord(
        id: 'rec-detail-test',
        createdAt: DateTime.utc(2026, 11, 24),
        latitude: 35.6812,
        longitude: 139.7671,
        summary: 'Old Cafe Summary',
        detectedLanguage: 'ja',
        distanceReasoning:
            'The camera is standing directly in front of the entrance 4m from the doorway.',
        tags: const {
          'amenity': 'cafe',
          'name': 'Kissa Green',
        },
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.aiEnriched,
      );
      await h.store.saveRecord(record);

      await tester.pumpWidget(
        h.buildApp(
          home: RecordDetailScreen(
            initialRecord: record,
            store: h.store,
            ai: h.ai,
            tiles: h.tiles,
            connectivity: h.connectivity,
            prefs: h.prefs,
            osmPublish: h.osmPublish,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Removed redundant buttons, Summary box, AI helper line, distance reasoning & bottom tags
      expect(find.text('Mark Ready'), findsNothing);
      expect(find.text('Save'), findsNothing);
      expect(find.text('Remove Record'), findsNothing);
      expect(find.text('Publish to OpenStreetMap'), findsNothing);
      expect(find.text('SUMMARY'), findsNothing);
      expect(find.text('Summary'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('Before / After diff'), findsNothing);
      expect(find.textContaining('standing directly in front'), findsNothing);
      expect(find.byType(Slider), findsNothing);
      expect(find.text('Firebase AI'), findsNothing);
      expect(find.text('AI Enriched'), findsNothing);
      expect(find.text('JA'), findsNothing);

      // Top AppBar has Delete visible directly and no top Publish button
      final appBar = find.byType(AppBar);
      expect(
        find.descendant(
          of: appBar,
          matching: find.byIcon(Icons.delete_outline_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: appBar,
          matching: find.byIcon(Icons.publish_rounded),
        ),
        findsNothing,
      );

      // Bottom dock has only Publish to OSM (no duplicate Add Tag button)
      final dock = find.byType(BottomActionDock);
      expect(dock, findsOneWidget);
      expect(
        find.descendant(of: dock, matching: find.text('Publish to OSM')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dock, matching: find.text('Add Tag')),
        findsNothing,
      );

      // Clean OSM Tags header
      expect(find.text('OSM TAGS'), findsOneWidget);
      expect(find.textContaining('tap book icon'), findsNothing);

      // 2D FinePinPositionPad uses a hand icon handle, displaces the pin accurately, and auto-saves
      final pad = find.byType(FinePinPositionPad);
      expect(pad, findsOneWidget);
      expect(
        find.descendant(
          of: pad,
          matching: find.byIcon(Icons.pan_tool_rounded),
        ),
        findsWidgets,
      );
      await tester.ensureVisible(pad);
      await tester.pumpAndSettle();

      final padBox = tester.getRect(pad);
      // Tap upper-right quadrant (North-East of camera)
      await tester.tapAt(
        Offset(padBox.center.dx + 40, padBox.center.dy - 20),
      );
      await tester.pumpAndSettle();

      final saved = h.store.records.firstWhere((r) => r.id == record.id);
      expect(saved.isManualPinOverride, isTrue);
      expect(saved.effectiveLatitude, greaterThan(record.latitude));
      expect(saved.effectiveLongitude, greaterThan(record.longitude));
      expect(tester.takeException(), isNull);
    });

    test('LocationContextService formats human-readable overall positions & offline regions', () {
      final mountainPlace =
          LocationContextService.formatOverallPlaceFromNominatim({
        'category': 'natural',
        'type': 'peak',
        'name': 'Mont Blanc',
        'address': {
          'peak': 'Mont Blanc',
          'town': 'Chamonix-Mont-Blanc',
          'county': 'Haute-Savoie',
          'country': 'France',
        },
      });
      expect(
        mountainPlace,
        equals('Mont Blanc, Chamonix-Mont-Blanc, Haute-Savoie, France'),
      );

      final cityPlace =
          LocationContextService.formatOverallPlaceFromNominatim({
        'category': 'amenity',
        'type': 'cafe',
        'name': 'Kissa Green',
        'address': {
          'city': 'Shibuya',
          'state': 'Tokyo',
          'country': 'Japan',
        },
      });
      expect(cityPlace, equals('Shibuya, Tokyo, Japan'));

      expect(
        LocationContextService.guessRegionOffline(45.9237, 6.8694),
        equals('France'),
      );
      expect(
        LocationContextService.guessRegionOffline(35.6812, 139.7671),
        equals('Japan'),
      );
    });

    testWidgets('RecordsScreen shows overall place, hides GPS/model/distance/tag & removes Drafts/Ready filters', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _TestHarness();
      h.connectivity.setForceOffline(true);

      final rec1 = OsmRecord(
        id: 'rec-overview-1',
        createdAt: DateTime.utc(2026, 11, 24),
        latitude: 45.9237,
        longitude: 6.8694,
        estimatedOffsetMeters: 3.0,
        summary: 'Mountain cafe',
        tags: const {
          'amenity': 'cafe',
          'name': 'Refuge du Mont',
        },
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.aiEnriched,
      );
      final rec2 = OsmRecord(
        id: 'rec-overview-2',
        createdAt: DateTime.utc(2026, 11, 23),
        latitude: 35.6812,
        longitude: 139.7671,
        estimatedOffsetMeters: 12.0,
        summary: 'Mountain peak',
        tags: const {
          'natural': 'peak',
          'name': 'Mount Takao',
        },
        aiSource: AiSource.mlKitOffline,
        status: RecordStatus.draftOffline,
      );
      await h.store.saveRecord(rec1);
      await h.store.saveRecord(rec2);
      h.store.seedPlaceLabel(
        45.9237,
        6.8694,
        'Chamonix-Mont-Blanc, Haute-Savoie, France',
      );

      await tester.pumpWidget(
        h.buildApp(
          home: Scaffold(
            body: RecordsScreen(
              store: h.store,
              ai: h.ai,
              tiles: h.tiles,
              connectivity: h.connectivity,
              prefs: h.prefs,
              osmPublish: h.osmPublish,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Overall human-readable position shown (resolved online label + offline fallback)
      expect(
        find.text('Chamonix-Mont-Blanc, Haute-Savoie, France'),
        findsOneWidget,
      );
      expect(find.text('Japan'), findsOneWidget);

      // Removed raw GPS, AI model, distance, and category tag from record cards
      expect(find.textContaining('45.9237'), findsNothing);
      expect(find.textContaining('35.6812'), findsNothing);
      expect(find.textContaining('Firebase AI'), findsNothing);
      expect(find.textContaining('Local AI'), findsNothing);
      expect(find.textContaining('3m'), findsNothing);
      expect(find.textContaining('amenity=cafe'), findsNothing);
      expect(find.textContaining('natural=peak'), findsNothing);

      // Removed Ready and Drafts filters; kept All, Enriched, Submitted
      expect(find.text('Ready'), findsNothing);
      expect(find.text('Drafts'), findsNothing);
      expect(find.text('All (2)'), findsOneWidget);
      expect(find.text('Enriched'), findsOneWidget);
      expect(find.text('Submitted'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('OsmDuplicateService.fetchSurroundingPois returns mapped POIs and buildings while excluding bare roads', () async {
      final client = MockClient((req) async {
        expect(req.url.path, contains('/api/0.6/map.json'));
        return http.Response(
          '''
          {
            "elements": [
              {"type": "node", "id": 1, "lat": 35.6812, "lon": 139.7671, "tags": {"amenity": "cafe", "name": "Kissa Green"}},
              {"type": "node", "id": 2, "lat": 35.6815, "lon": 139.7673, "tags": {"highway": "bus_stop", "name": "Station Bus Stop"}},
              {"type": "node", "id": 3, "lat": 35.6810, "lon": 139.7670},
              {"type": "node", "id": 4, "lat": 35.6811, "lon": 139.7672},
              {"type": "node", "id": 5, "lat": 35.6813, "lon": 139.7672},
              {"type": "node", "id": 6, "lat": 35.6813, "lon": 139.7670},
              {"type": "way", "id": 10, "nodes": [3, 4], "tags": {"highway": "residential", "name": "Main Street"}},
              {"type": "way", "id": 11, "nodes": [3, 4, 5, 6, 3], "tags": {"building": "yes"}}
            ]
          }
          ''',
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = OsmDuplicateService(client: client);
      final res = await service.fetchSurroundingPois(
        lat: 35.6812,
        lon: 139.7671,
      );

      expect(res.succeeded, isTrue);
      expect(res.elements.map((e) => e.id).toSet(), equals({1, 2, 11}));
      final bldg = res.elements.firstWhere((e) => e.id == 11);
      expect(bldg.isBuilding, isTrue);
      expect(bldg.hasPolygonGeometry, isTrue);
      expect(bldg.missingRecommendedKeys, contains('building:levels'));
    });

    testWidgets('CaptureScreen replaces character XP card with Mapped Nearby coverage map', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _TestHarness();
      h.connectivity.setForceOffline(true);
      await tester.pumpWidget(h.buildApp());
      await tester.pumpAndSettle();

      // Redundant top GpsWarningBanner is removed; single telemetry card keeps Compass + right-aligned Retry
      expect(find.byType(GpsWarningBanner), findsNothing);
      expect(find.byType(CompassBadge), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      final compassRect = tester.getRect(find.byType(CompassBadge));
      final retryRect = tester.getRect(find.text('Retry'));
      expect(retryRect.left, greaterThan(compassRect.right));

      // Character / level / XP card is removed from Capture screen
      expect(find.byType(MapperQuestBar), findsNothing);

      // Surrounding mapped coverage map & obvious legend are shown instead
      expect(find.text('Mapped Nearby'), findsOneWidget);
      expect(find.byType(OsmMapWidget), findsOneWidget);
      expect(find.text('POI'), findsOneWidget);
      expect(find.text('Building'), findsOneWidget);
      expect(find.text('Yours'), findsOneWidget);

      final mapWidget = tester.widget<OsmMapWidget>(find.byType(OsmMapWidget));
      expect(mapWidget.highlightMappedCoverage, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Selecting a mapped building on CaptureScreen shows tag overview and saves added tags', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final mockClient = MockClient((req) async {
        return http.Response(
          '''
          {
            "elements": [
              {"type": "node", "id": 101, "lat": 35.6810, "lon": 139.7669},
              {"type": "node", "id": 102, "lat": 35.6810, "lon": 139.7673},
              {"type": "node", "id": 103, "lat": 35.6814, "lon": 139.7673},
              {"type": "node", "id": 104, "lat": 35.6814, "lon": 139.7669},
              {"type": "way", "id": 500, "nodes": [101, 102, 103, 104, 101], "tags": {"building": "yes"}}
            ]
          }
          ''',
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final h = _TestHarness(initialOnline: true);
      await tester.pumpWidget(
        h.buildApp(
          home: Scaffold(
            body: CaptureScreen(
              store: h.store,
              sensors: h.sensors,
              ai: h.ai,
              connectivity: h.connectivity,
              onRecordSaved: () {},
              nearbyOsmService: OsmDuplicateService(client: mockClient),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap scan radar button to load surrounding mapped buildings/POIs
      final scanBtn = find.byIcon(Icons.radar_rounded);
      expect(scanBtn, findsOneWidget);
      await tester.tap(scanBtn);
      await tester.pumpAndSettle();
      expect(find.text('1 OSM'), findsOneWidget);

      // Tap right in the center of the map where the building polygon sits
      final mapFinder = find.byType(OsmMapWidget);
      await tester.ensureVisible(mapFinder);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(mapFinder));
      await tester.pumpAndSettle();

      // Inline tag overview shows existing tags, missing hints, and Add / Improve Tags CTA
      expect(find.text('building=yes'), findsWidgets);
      expect(find.textContaining('way/500'), findsOneWidget);
      expect(find.textContaining('Could add:'), findsOneWidget);
      expect(find.text('Add / Improve Tags'), findsOneWidget);

      // Open tag improvement sheet, add building:levels=3, and save locally
      await tester.ensureVisible(find.text('Add / Improve Tags'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add / Improve Tags'));
      await tester.pumpAndSettle();

      expect(find.text('building:levels'), findsOneWidget);
      await tester.tap(find.text('building:levels'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();

      expect(find.text('Save Improvement (+1 tag)'), findsOneWidget);
      await tester.tap(find.text('Save Improvement (+1 tag)'));
      await tester.pumpAndSettle();

      // Saved locally in MapperStore with original + new tag
      expect(h.store.records.length, equals(1));
      expect(h.store.records.first.tags['building'], equals('yes'));
      expect(h.store.records.first.tags['building:levels'], equals('3'));
      expect(tester.takeException(), isNull);
    });

    test('OsmPublishService.buildOsmChangeDiffLines marks added, modified, and removed tags like Git diff', () {
      final diffLines = OsmPublishService.buildOsmChangeDiffLines(
        changesetId: 42,
        tagUpdates: [
          const OsmElementTagUpdate(
            elementType: 'way',
            elementId: 500,
            version: 3,
            nodeIds: [101, 102, 103, 101],
            existingTags: {
              'building': 'yes',
              'name': 'Old Name',
              'day_off': 'Monday',
            },
            selectedNewTags: {
              'name': 'New Cafe House',
              'building:levels': '3',
            },
            removedTagKeys: {'day_off'},
          ),
        ],
      );

      final added = diffLines
          .where((l) => l.kind == XmlDiffLineKind.added)
          .map((l) => l.text)
          .toList();
      final removed = diffLines
          .where((l) => l.kind == XmlDiffLineKind.removed)
          .map((l) => l.text)
          .toList();
      final context = diffLines
          .where((l) => l.kind == XmlDiffLineKind.context)
          .map((l) => l.text)
          .toList();

      expect(context.any((t) => t.contains('k="building" v="yes"')), isTrue);
      expect(removed.any((t) => t.contains('k="name" v="Old Name"')), isTrue);
      expect(added.any((t) => t.contains('k="name" v="New Cafe House"')), isTrue);
      expect(added.any((t) => t.contains('k="building:levels" v="3"')), isTrue);
      expect(removed.any((t) => t.contains('k="day_off" v="Monday"')), isTrue);
    });

    testWidgets('OsmPublishSheet lets user pick target building/point for merge and shows Git-style XML diff', (tester) async {
      tester.view.physicalSize = const Size(420, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final mockClient = MockClient((req) async {
        return http.Response(
          '''
          {
            "elements": [
              {"type": "node", "id": 101, "version": 2, "lat": 35.6812, "lon": 139.7671, "tags": {"amenity": "cafe", "name": "Kissa Green"}},
              {"type": "node", "id": 201, "lat": 35.6811, "lon": 139.7670},
              {"type": "node", "id": 202, "lat": 35.6811, "lon": 139.7672},
              {"type": "node", "id": 203, "lat": 35.6813, "lon": 139.7672},
              {"type": "node", "id": 204, "lat": 35.6813, "lon": 139.7670},
              {"type": "way", "id": 500, "version": 4, "nodes": [201, 202, 203, 204, 201], "tags": {"building": "yes", "name": "Old Building"}}
            ]
          }
          ''',
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final h = _TestHarness(initialOnline: true);
      final rec = OsmRecord(
        id: 'rec-merge-target-1',
        createdAt: DateTime.utc(2026, 11, 24),
        latitude: 35.6812,
        longitude: 139.7671,
        summary: 'Kissa Green',
        tags: const {
          'amenity': 'cafe',
          'name': 'Kissa Green',
          'building:levels': '3',
        },
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.readyToUpload,
      );

      await tester.pumpWidget(
        h.buildApp(
          home: Scaffold(
            body: OsmPublishSheet(
              osm: h.osmPublish,
              store: h.store,
              prefs: h.prefs,
              connectivity: h.connectivity,
              initialRecords: [rec],
              duplicateService: OsmDuplicateService(client: mockClient),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially matched the cafe node/101, and target picker dropdown is visible
      expect(find.textContaining('node/101'), findsWidgets);
      final targetDropdown = find.byType(DropdownButtonFormField<String>);
      expect(targetDropdown, findsOneWidget);

      // Switch target to the nearby building way/500!
      await tester.ensureVisible(targetDropdown);
      await tester.pumpAndSettle();
      await tester.tap(targetDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('way/500').last);
      await tester.pumpAndSettle();

      // Now targeting way/500 (building)
      expect(find.text('Update existing way/500 on OSM'), findsOneWidget);

      // Open Git-style XML diff preview and verify + added and - removed indicators
      final diffTile = find.textContaining('Preview OsmChange XML Diff');
      await tester.ensureVisible(diffTile);
      await tester.pumpAndSettle();
      await tester.tap(diffTile);
      await tester.pumpAndSettle();

      expect(find.textContaining('added'), findsOneWidget);
      expect(find.textContaining('removed'), findsOneWidget);
      expect(
        find.textContaining('-       <tag k="name" v="Old Building"/>'),
        findsOneWidget,
      );
      expect(
        find.textContaining('+       <tag k="name" v="Kissa Green"/>'),
        findsOneWidget,
      );
      expect(
        find.textContaining('+       <tag k="building:levels" v="3"/>'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('OsmPublishSheet shows pre-publish AI hallucination review warning and blocks/fixes Taginfo-invalid tags', (tester) async {
      tester.view.physicalSize = const Size(420, 920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final mockDupClient = MockClient((req) async {
        return http.Response(
          '{"elements": []}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final mockTaginfo = MockClient((req) async {
        return http.Response(
          '{"data": {"in_wiki": false, "counts": [{"type": "all", "count": 0}]}}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final h = _TestHarness(initialOnline: true);
      final rec = OsmRecord(
        id: 'rec-hallucination-check',
        createdAt: DateTime.utc(2026, 11, 25),
        latitude: 35.6812,
        longitude: 139.7671,
        summary: 'Park Bench',
        tags: const {
          'amenity': 'bench',
          'material': 'quantum_titanium',
          'source': 'survey;GPS',
        },
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.readyToUpload,
      );

      await tester.pumpWidget(
        h.buildApp(
          home: Scaffold(
            body: OsmPublishSheet(
              osm: h.osmPublish,
              store: h.store,
              prefs: h.prefs,
              connectivity: h.connectivity,
              initialRecords: [rec],
              duplicateService: OsmDuplicateService(client: mockDupClient),
              tagVerifier: OsmTagVerifierService(client: mockTaginfo),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Taginfo rejected material=quantum_titanium -> shown as confirmed invalid & blocks upload
      expect(
        find.text('Invalid / Hallucinated OSM Tag(s) Detected'),
        findsOneWidget,
      );
      expect(
        find.textContaining('material=quantum_titanium'),
        findsOneWidget,
      );
      // Always displays the AI hallucination review reminder before publishing
      expect(
        find.textContaining('AI can still hallucinate or misread'),
        findsOneWidget,
      );

      // Tap one-tap "Remove Invalid Tag(s)" to strip the hallucinated tag
      final removeBtn = find.text('Remove Invalid Tag(s)');
      await tester.ensureVisible(removeBtn);
      await tester.pumpAndSettle();
      await tester.tap(removeBtn);
      await tester.pumpAndSettle();

      // Invalid tag banner resolves into the clean pre-publish AI hallucination review banner!
      expect(
        find.text('Review Before Publishing — Possible AI Hallucinations'),
        findsOneWidget,
      );
      expect(find.text('Tags Checked'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('FirebaseAuthSheet invites initialization when no key exists, unlocks existing key with Fingerprint, uses one Sync Now button, simplifies Sync Another Device, and removes Lock Vault & Forget Key', (tester) async {
      tester.view.physicalSize = const Size(420, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _TestHarness(initialOnline: true);

      // 1. Fresh device (no key yet) -> invites user to initialize Cloud Sync
      const freshBridge = _FakeAndroidKeystoreBridge(hasCached: false);
      String? freshUid;
      final freshFb = FirebaseSyncService(
        prefs: UserPreferencesService(),
        platformBridge: freshBridge,
        uidOverride: () => freshUid,
        projectIdOverride: () => 'test-e2ee-ui',
        vaultAuthOverride: (creds, {required bool createNew}) async {
          freshUid = 'uid-fresh-test';
        },
        authSignOutOverride: () async => freshUid = null,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: FirebaseAuthSheet(
              key: const ValueKey('fresh'),
              firebaseSync: freshFb,
              store: h.store,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Initialize Cloud Sync'), findsOneWidget);
      expect(find.text('Already using another device?'), findsOneWidget);
      expect(find.text('Account Email'), findsNothing);
      expect(find.text('Account Password'), findsNothing);
      expect(find.text('Sync Key'), findsNothing);

      // Tapping "Already using another device?" reveals the simple Sync Key form
      await tester.tap(find.text('Already using another device?'));
      await tester.pumpAndSettle();
      expect(find.byType(AutofillGroup), findsOneWidget);
      expect(find.text('Sync Key'), findsOneWidget);
      expect(find.text('Connect & Sync'), findsOneWidget);

      // 2. Existing device (already has hardware key) -> offers ONLY Fingerprint unlock (no second Initialize)
      const existingBridge = _FakeAndroidKeystoreBridge(hasCached: true);
      String? existingUid;
      final existingFb = FirebaseSyncService(
        prefs: UserPreferencesService(),
        platformBridge: existingBridge,
        uidOverride: () => existingUid,
        projectIdOverride: () => 'test-e2ee-ui',
        vaultAuthOverride: (creds, {required bool createNew}) async {
          existingUid = 'uid-ui-test';
        },
        authSignOutOverride: () async => existingUid = null,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: FirebaseAuthSheet(
              key: const ValueKey('existing'),
              firebaseSync: existingFb,
              store: h.store,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Unlock with Fingerprint'), findsWidgets);
      expect(find.text('Initialize Cloud Sync'), findsNothing);

      // 3. Unlocked view -> ONE Sync Now button, simple Sync Another Device, NO Re-Upload All, NO Lock Vault, NO Forget Key
      existingUid = 'uid-ui-test';
      existingFb.setUnlockedKeyPairForTest(X25519.generateKeyPair());
      await tester.pumpAndSettle();

      expect(find.text('Sync Now'), findsOneWidget);
      expect(find.text('Encrypt & Re-Upload All Local Data'), findsNothing);
      expect(find.text('Lock Vault'), findsNothing);
      expect(find.text('Forget Key'), findsNothing);
      expect(find.text('Sync Another Device'), findsOneWidget);
      expect(find.text('Show QR'), findsOneWidget);
      expect(find.text('Copy Key'), findsOneWidget);
      expect(find.text('Selective Sharing & Share Links'), findsNothing);
      expect(find.text('Create #k= Share Link'), findsNothing);

      // Tapping Show QR displays the QR code widget cleanly
      await tester.tap(find.text('Show QR'));
      await tester.pumpAndSettle();
      expect(find.byType(QrCodeWidget), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('HomeShell Sync icon highlights and badges pending cloud deletions after removing local data', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final db = _InMemoryLocalDbService();
      final prefs = UserPreferencesService();
      final connectivity = ConnectivityService(initialHasNetwork: true);
      final tiles = OfflineTileService();
      final sensors = SensorService();
      final ai = HybridAiService(connectivity: connectivity, prefs: prefs);
      final fb = FirebaseSyncService(
        prefs: prefs,
        uidOverride: () => 'uid-home-del',
        projectIdOverride: () => 'test-e2ee-home',
      );
      fb.setUnlockedKeyPairForTest(X25519.generateKeyPair());
      final osmPublish = OsmPublishService(prefs: prefs);
      final leaderboard = LeaderboardService(
        prefs: prefs,
        firebaseSync: fb,
        connectivity: connectivity,
      );
      final bounties = BountyService(
        db: db,
        prefs: prefs,
        firebaseSync: fb,
        connectivity: connectivity,
      );
      final store = MapperStore(
        db: db,
        sensors: sensors,
        ai: ai,
        connectivity: connectivity,
        prefs: prefs,
        firebaseSync: fb,
        tiles: tiles,
      );
      final syncedRec = OsmRecord(
        id: 'rec-home-delete-1',
        createdAt: DateTime.utc(2026, 11, 25),
        latitude: 35.6812,
        longitude: 139.7671,
        summary: 'Synced Fountain',
        tags: const {'amenity': 'fountain'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.aiEnriched,
        firebaseSyncedAt: DateTime.utc(2026, 11, 25, 1),
      );
      await db.upsertRecord(syncedRec);
      await store.reload();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: HomeShell(
            connectivity: connectivity,
            sensors: sensors,
            ai: ai,
            store: store,
            prefs: prefs,
            firebaseSync: fb,
            tiles: tiles,
            osmPublish: osmPublish,
            leaderboard: leaderboard,
            bounties: bounties,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially 0 pending changes -> no pending-delete tooltip
      expect(
        find.byTooltip('Sync to remove 1 deleted item from Firestore'),
        findsNothing,
      );

      final lightSemantic = AppTheme.light().extension<AppSemanticColors>()!;

      // 1. Add an unsynced record -> Sync icon & badge turn GREEN with count 1
      await store.saveRecord(
        OsmRecord(
          id: 'rec-home-added-1',
          createdAt: DateTime.utc(2026, 11, 25, 2),
          latitude: 35.6815,
          longitude: 139.7675,
          summary: 'New Bench',
          tags: const {'amenity': 'bench'},
          aiSource: AiSource.firebaseCloud,
          status: RecordStatus.aiEnriched,
        ),
      );
      await tester.pumpAndSettle();

      final addBadge = tester.widget<Badge>(
        find.ancestor(
          of: find.byIcon(Icons.sync_rounded),
          matching: find.byType(Badge),
        ),
      );
      expect(addBadge.isLabelVisible, isTrue);
      expect(addBadge.backgroundColor, equals(lightSemantic.success));
      final addIcon = tester.widget<Icon>(find.byIcon(Icons.sync_rounded));
      expect(addIcon.color, equals(lightSemantic.success));

      // 2. Remove the synced record locally -> Sync icon & badge turn RED and suggest removing on Firestore!
      await store.deleteRecord('rec-home-delete-1');
      await tester.pumpAndSettle();

      final delBadge = tester.widget<Badge>(
        find.ancestor(
          of: find.byIcon(Icons.sync_rounded),
          matching: find.byType(Badge),
        ),
      );
      expect(delBadge.isLabelVisible, isTrue);
      expect(delBadge.backgroundColor, equals(lightSemantic.danger));
      final delIcon = tester.widget<Icon>(find.byIcon(Icons.sync_rounded));
      expect(delIcon.color, equals(lightSemantic.danger));
      // Drain Nominatim place-lookup throttle timers queued when saving records
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('No cloud status icons on records/routes, and route deletion matches record deletion (card trash + confirm + multi-select + detail AppBar trash)', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _TestHarness(initialOnline: false);
      final trailA = HikeTrail(
        id: 'trail-del-a',
        name: 'Morning River Walk',
        startedAt: DateTime.utc(2026, 11, 25, 8, 0),
        endedAt: DateTime.utc(2026, 11, 25, 8, 30),
        isActive: false,
        tags: const {'highway': 'footway'},
        firebaseSyncedAt: DateTime.utc(2026, 11, 25, 9, 0),
        points: [
          TrailPoint(
            trailId: 'trail-del-a',
            latitude: 35.68,
            longitude: 139.76,
            recordedAt: DateTime.utc(2026, 11, 25, 8, 5),
          ),
        ],
      );
      final trailB = HikeTrail(
        id: 'trail-del-b',
        name: 'Evening Park Stroll',
        startedAt: DateTime.utc(2026, 11, 25, 18, 0),
        endedAt: DateTime.utc(2026, 11, 25, 18, 25),
        isActive: false,
        tags: const {'highway': 'footway'},
        firebaseSyncedAt: DateTime.utc(2026, 11, 25, 19, 0),
        points: [
          TrailPoint(
            trailId: 'trail-del-b',
            latitude: 35.69,
            longitude: 139.77,
            recordedAt: DateTime.utc(2026, 11, 25, 18, 5),
          ),
        ],
      );
      await h.db.upsertTrail(trailA);
      await h.db.upsertTrail(trailB);
      await h.store.reload();

      await tester.pumpWidget(
        h.buildApp(
          home: Scaffold(
            body: TrailScreen(
              store: h.store,
              sensors: h.sensors,
              tiles: h.tiles,
              connectivity: h.connectivity,
              prefs: h.prefs,
              ai: h.ai,
              osmPublish: h.osmPublish,
              onSnapAlongTrail: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Zero cloud status icons on route cards
      expect(find.byIcon(Icons.cloud_done_outlined), findsNothing);
      expect(find.byIcon(Icons.cloud_done_rounded), findsNothing);
      expect(find.byIcon(Icons.cloud_upload_outlined), findsNothing);

      // Direct 1-tap trash icon on each saved route card + confirmation dialog (identical to RecordsScreen)
      final trashBtn = find.byTooltip('Remove route').first;
      await tester.ensureVisible(trashBtn);
      await tester.pumpAndSettle();
      await tester.tap(trashBtn);
      await tester.pumpAndSettle();
      expect(find.text('Remove Route?'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      // Let the removal SnackBar dismiss before interacting with the bottom dock
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(h.store.trails.length, equals(1));

      // Multi-select mode via checklist button -> checkboxes & thumb-dock Remove (1)
      final selectBtn = find.byTooltip('Select routes');
      await tester.ensureVisible(selectBtn);
      await tester.pumpAndSettle();
      await tester.tap(selectBtn);
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsOneWidget);
      await tester.ensureVisible(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(find.text('Remove (1)'), findsOneWidget);
      await tester.tap(find.text('Remove (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Remove 1 Route?'), findsOneWidget);
      await tester.tap(find.text('Remove (1)').last);
      await tester.pumpAndSettle();
      expect(h.store.trails, isEmpty);

      // TrailDetailScreen has direct red trash icon in AppBar and NO cloud status icon
      await h.db.upsertTrail(trailA);
      await h.store.reload();
      await tester.pumpWidget(
        h.buildApp(
          home: TrailDetailScreen(
            initialTrail: trailA,
            store: h.store,
            tiles: h.tiles,
            connectivity: h.connectivity,
            prefs: h.prefs,
            ai: h.ai,
            osmPublish: h.osmPublish,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.cloud_done_rounded), findsNothing);
      expect(find.byIcon(Icons.cloud_upload_outlined), findsNothing);
      expect(find.byTooltip('Delete route'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete route'));
      await tester.pumpAndSettle();
      expect(find.text('Remove Route?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('CommunityScreen hides Bounties & Hero tabs and shows OSM Ranking directly', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _TestHarness(initialOnline: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: CommunityScreen(
              store: h.store,
              sensors: h.sensors,
              prefs: h.prefs,
              connectivity: h.connectivity,
              leaderboard: h.leaderboard,
              bounties: h.bounties,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Bounties'), findsNothing);
      expect(find.text('Hero'), findsNothing);
      expect(find.text('Hero & Proof'), findsNothing);
      expect(find.text('Real OpenStreetMap Mappers Near POI'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('BitcoinPaymentSheet merges BOLT 12 & Lightning with Email/BOLT 12 toggle, uses Onchain label, and shows compact amount chips', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const testP2tr =
          'bc1p5d7rjq7g6rdk2yhzks9smlaqtedr4dekq08ge8ztwac72sfr9rusxg3297';
      const testSilentPayment =
          'sp1qqgste7k9hx0qftg6qmwlkqtwuy6cycyavzmzj85c6qdfjdpdjtdgqjuexzk6murw56suy3e0rd2cgqvycxttddwsvgxe2usfpxumr70xc9rmdjhw';
      const testLightning = 'mapper@example.org';
      final testBolt12Uri = 'bitcoin:?lno=lno1${'q' * 120}';

      final config = BitcoinDonationConfig(
        bitcoinUri: testBolt12Uri,
        lightningAddress: testLightning,
        silentPaymentAddress: testSilentPayment,
        p2trAddress: testP2tr,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: BitcoinPaymentSheet(
              title: 'Support Edge Mapper with Bitcoin',
              subtitle: 'Direct developer donations',
              options: config.availableOptions,
              paymentLabel: 'Edge Mapper',
              paymentMessage: 'Thanks!',
              showMarkAsPaidButton: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // BOLT 12 URI and Lightning are merged into ONE Lightning tab; Taproot (P2TR) is now Onchain
      expect(find.text('Lightning'), findsOneWidget);
      expect(find.text('BOLT 12 URI'), findsNothing);
      expect(find.text('Onchain'), findsOneWidget);
      expect(find.text('Taproot (P2TR)'), findsNothing);
      expect(find.text('Silent Payment'), findsOneWidget);

      // Amount selector sits ON TOP of payment methods (including on Lightning Email format!)
      expect(find.text('Coffee'), findsOneWidget);
      expect(find.text('Lunch'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Coffee')).dy,
        lessThan(tester.getTopLeft(find.text('Lightning')).dy),
      );

      // Inside Lightning tab: toggle between Email format and BOLT 12, NO "Payment URI ready" text
      expect(find.text('Email format'), findsOneWidget);
      expect(find.text('BOLT 12'), findsOneWidget);
      expect(find.text(testLightning), findsOneWidget);
      expect(find.text('Copy URI'), findsOneWidget);
      expect(find.textContaining('Payment URI ready'), findsNothing);

      // Switch to BOLT 12 mode -> abbreviates BOLT 12 offer (NOT shown in full) + friendly word amount chips
      await tester.tap(find.text('BOLT 12'));
      await tester.pumpAndSettle();
      expect(find.text(testBolt12Uri), findsNothing);
      expect(find.textContaining('lno1qqqqqqqqqqqqqq…'), findsOneWidget);
      expect(find.textContaining('Payment URI ready'), findsNothing);
      expect(find.text('Any'), findsOneWidget);
      expect(find.text('Coffee'), findsOneWidget);
      expect(find.text('Lunch'), findsOneWidget);
      expect(find.text('Dinner'), findsOneWidget);
      expect(find.text('Patron'), findsOneWidget);
      expect(find.text('2.1k'), findsNothing);

      // Switch to Onchain tab -> shows abbreviated Onchain address, friendly amount words & Copy URI
      await tester.tap(find.text('Onchain'));
      await tester.pumpAndSettle();
      expect(find.text(testP2tr), findsNothing);
      expect(
        find.text(BitcoinService.abbreviateDestination(testP2tr)),
        findsOneWidget,
      );
      expect(find.text('Coffee'), findsOneWidget);
      expect(find.text('Copy URI'), findsOneWidget);
      expect(find.textContaining('Payment URI ready'), findsNothing);
      expect(find.text('Email format'), findsNothing);

      // Switch to Silent Payment tab -> shows abbreviated Silent Payment address & friendly amount words
      await tester.tap(find.text('Silent Payment'));
      await tester.pumpAndSettle();
      expect(find.text(testSilentPayment), findsNothing);
      expect(
        find.text(BitcoinService.abbreviateDestination(testSilentPayment)),
        findsOneWidget,
      );
      expect(find.text('Coffee'), findsOneWidget);
      expect(find.textContaining('Payment URI ready'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

class _FakeAndroidKeystoreBridge implements E2eePlatformBridge {
  final bool hasCached;

  const _FakeAndroidKeystoreBridge({this.hasCached = true});

  @override
  Future<E2eePlatformCapabilities> getCapabilities() async =>
      const E2eePlatformCapabilities(
        supportsWebAuthnPrf: false,
        supportsAndroidHardwareCache: true,
        hardwareCacheDetail: 'Android Keystore AES-256-GCM',
      );

  @override
  Future<bool> cacheUserPrivLocally({
    required String uid,
    required Uint8List userPrivateKey,
    Uint8List? authSeed16,
  }) async =>
      true;

  @override
  Future<void> clearCachedUserPriv({String? uid}) async {}

  @override
  Future<PasskeyPrfResult> enrollPasskeyPrf({
    required String accountName,
    required String displayName,
    required Uint8List deterministicSalt,
  }) async =>
      const PasskeyPrfResult(webAuthnSupported: false, prfSupported: false);

  @override
  Future<PasskeyPrfResult> evaluatePasskeyPrf({
    required Uint8List deterministicSalt,
    String? credentialIdB64,
  }) async =>
      const PasskeyPrfResult(webAuthnSupported: false, prfSupported: false);

  @override
  Future<bool> hasCachedUserPriv({String? uid}) async => hasCached;

  @override
  Future<CachedHardwareVault?> loadCachedVault({String? uid}) async => null;

  @override
  Future<CachedHardwareVault?> unlockCachedVaultWithBiometric({
    String? uid,
  }) async =>
      null;
}
