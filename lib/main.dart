import 'package:flutter/material.dart';

import 'screens/home_shell.dart';
import 'services/app_env_config.dart';
import 'services/bounty_service.dart';
import 'services/connectivity_service.dart';
import 'services/firebase_bootstrap.dart';
import 'services/firebase_sync_service.dart';
import 'services/hybrid_ai_service.dart';
import 'services/leaderboard_service.dart';
import 'services/local_db_service.dart';
import 'services/mapper_store.dart';
import 'services/offline_tile_service.dart';
import 'services/osm_publish_service.dart';
import 'services/secure_vault_service.dart';
import 'services/sensor_service.dart';
import 'services/user_preferences_service.dart';
import 'theme/app_theme.dart';
import 'attest_gate_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase safely (app still boots offline if google-services.json is not yet added)
  await FirebaseBootstrap.init();

  // Wire AttestGate hardware-attested App Check AFTER Firebase Core is ready and
  // BEFORE any FirebaseAI instance is created (configured via ATTEST_GATE_BASE_URL in .env).
  if (FirebaseBootstrap.isConfigured) {
    try {
      await AttestGateAppCheck.initialize(
        attestGateBaseUrl: AppEnvConfig.attestGateBaseUrl,
        webRecaptchaSiteKey: AppEnvConfig.firebaseWebRecaptchaSiteKey,
        webDebugToken: AppEnvConfig.firebaseWebAppCheckDebugToken,
);
      );
    } catch (e) {
      debugPrint('[EdgeMapper] AttestGate App Check init skipped: $e');
    }
  }

  final db = LocalDbService();
  await db.init();

  final vault = SecureVaultService();
  await vault.init();

  final prefs = UserPreferencesService(db: db, vault: vault);
  await prefs.init();

  final connectivity = ConnectivityService();
  await connectivity.init();

  final tiles = OfflineTileService();
  await tiles.init();

  final sensors = SensorService();
  final ai = HybridAiService(connectivity: connectivity, prefs: prefs);
  final firebaseSync = FirebaseSyncService(prefs: prefs);
  final osmPublish = OsmPublishService(prefs: prefs);
  final leaderboard = LeaderboardService(
    prefs: prefs,
    firebaseSync: firebaseSync,
    connectivity: connectivity,
    db: db,
  );
  final bounties = BountyService(
    db: db,
    prefs: prefs,
    firebaseSync: firebaseSync,
    connectivity: connectivity,
  );
  final store = MapperStore(
    db: db,
    sensors: sensors,
    ai: ai,
    connectivity: connectivity,
    prefs: prefs,
    firebaseSync: firebaseSync,
    tiles: tiles,
  );

  await Future.wait([
    ai.init(),
    firebaseSync.refreshSessionAndTryAutoUnlock(),
    store.init(),
    bounties.init(),
    leaderboard.init(),
  ]);

  // Request GPS & compass streams after core storage is ready
  // ignore: unawaited_futures
  sensors.init();

  runApp(
    EdgeMapperApp(
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

class EdgeMapperApp extends StatefulWidget {
  final ConnectivityService connectivity;
  final SensorService sensors;
  final HybridAiService ai;
  final MapperStore store;
  final UserPreferencesService prefs;
  final FirebaseSyncService firebaseSync;
  final OfflineTileService tiles;
  final OsmPublishService osmPublish;
  final LeaderboardService leaderboard;
  final BountyService bounties;

  const EdgeMapperApp({
    super.key,
    required this.connectivity,
    required this.sensors,
    required this.ai,
    required this.store,
    required this.prefs,
    required this.firebaseSync,
    required this.tiles,
    required this.osmPublish,
    required this.leaderboard,
    required this.bounties,
  });

  @override
  State<EdgeMapperApp> createState() => _EdgeMapperAppState();
}

class _EdgeMapperAppState extends State<EdgeMapperApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.firebaseSync.lockVault();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Automatically lock & zeroize volatile E2EE keys when the app is closed,
    // without interrupting minimized background trail recording (`paused`).
    if (state == AppLifecycleState.detached) {
      widget.firebaseSync.lockVault();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Edge Mapper',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: HomeShell(
        connectivity: widget.connectivity,
        sensors: widget.sensors,
        ai: widget.ai,
        store: widget.store,
        prefs: widget.prefs,
        firebaseSync: widget.firebaseSync,
        tiles: widget.tiles,
        osmPublish: widget.osmPublish,
        leaderboard: widget.leaderboard,
        bounties: widget.bounties,
      ),
    );
  }
}
