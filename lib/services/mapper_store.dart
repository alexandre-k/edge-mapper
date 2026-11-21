import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' hide ActivityType;
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../data/osm_tag_standards.dart';
import '../models/enrichment_diff.dart';
import '../models/hike_trail.dart';
import '../models/osm_record.dart';
import 'connectivity_service.dart';
import 'firebase_sync_service.dart';
import 'gamification_service.dart';
import 'ham_radio_gps_import_service.dart';
import 'hybrid_ai_service.dart';
import 'local_db_service.dart';
import 'location_context_service.dart';
import 'offline_tile_service.dart';
import 'photo_helper.dart';
import 'sensor_service.dart';
import 'user_preferences_service.dart';

/// Central offline-first store coordinating OSM records, general activity routes
/// (walks, park strolls, hikes, cycling), automatic online location guessing,
/// Firebase Cloud Firestore backup, offline map prefetching, and Explorer XP.
class MapperStore extends ChangeNotifier {
  final LocalDbService db;
  final SensorService sensors;
  final HybridAiService ai;
  final ConnectivityService connectivity;
  final UserPreferencesService prefs;
  final FirebaseSyncService firebaseSync;
  final OfflineTileService tiles;

  final Uuid _uuid = const Uuid();

  List<OsmRecord> _records = [];
  List<HikeTrail> _trails = [];
  HikeTrail? _activeTrail;
  StreamSubscription<Position>? _hikeGpsSub;

  bool _isEnrichingBatch = false;
  int _batchEnrichDone = 0;
  int _batchEnrichTotal = 0;
  int _batchEnrichSucceeded = 0;
  int _batchEnrichFailed = 0;
  String _batchEnrichStatus = '';
  bool _cancelBatchRequested = false;
  String? _lastBatchEnrichError;
  List<EnrichmentDiff> _pendingBatchDiffs = [];

  bool _isSyncingFirebase = false;
  bool _wasOnline = false;
  LocationGuess? _lastLocationGuess;
  final Set<String> _pendingRemoteDeleteRecordIds = {};
  final Set<String> _pendingRemoteDeleteTrailIds = {};
  final Map<String, String> _placeLabelCache = {};
  final Set<String> _failedPlaceLookupKeys = {};
  final List<({String key, double lat, double lon})> _placeLookupQueue = [];
  bool _isResolvingPlaceQueue = false;

  static const String _pendingDeleteSettingKey = 'pending_deleted_record_ids';
  static const String _pendingDeleteTrailSettingKey =
      'pending_deleted_trail_ids';
  static const String _placeLabelCacheSettingKey = 'place_label_cache_v1';

  MapperStore({
    required this.db,
    required this.sensors,
    required this.ai,
    required this.connectivity,
    required this.prefs,
    required this.firebaseSync,
    required this.tiles,
  });

  List<OsmRecord> get records => List.unmodifiable(_records);
  List<HikeTrail> get trails => List.unmodifiable(_trails);
  HikeTrail? get activeTrail => _activeTrail;
  bool get isRecordingTrail => _activeTrail != null;
  bool get isEnrichingBatch => _isEnrichingBatch;
  int get batchEnrichDone => _batchEnrichDone;
  int get batchEnrichTotal => _batchEnrichTotal;
  int get batchEnrichSucceeded => _batchEnrichSucceeded;
  int get batchEnrichFailed => _batchEnrichFailed;
  String get batchEnrichStatus => _batchEnrichStatus;
  bool get batchEnrichCancelled => _cancelBatchRequested;
  String? get lastBatchEnrichError => _lastBatchEnrichError;
  List<EnrichmentDiff> get pendingBatchDiffs =>
      List.unmodifiable(_pendingBatchDiffs);
  bool get isSyncingFirebase => _isSyncingFirebase;
  LocationGuess? get lastLocationGuess => _lastLocationGuess;

  List<OsmRecord> get offlineDraftRecords =>
      _records.where((r) => r.status == RecordStatus.draftOffline).toList();

  List<OsmRecord> get unsyncedRecords =>
      _records.where((r) => !r.isSyncedToFirebase).toList();

  List<HikeTrail> get unsyncedTrails =>
      _trails.where((t) => !t.isActive && !t.isSyncedToFirebase).toList();

  int get pendingRemoteDeleteCount =>
      _pendingRemoteDeleteRecordIds.length +
      _pendingRemoteDeleteTrailIds.length;

  bool get hasPendingRemoteDeletes => pendingRemoteDeleteCount > 0;

  int get totalUnsyncedCount =>
      unsyncedRecords.length + unsyncedTrails.length + pendingRemoteDeleteCount;

  /// Backup reminder banners are disabled; users trigger sync directly from
  /// Settings → Cloud Backup & Sync or the sync action button.
  bool get shouldSuggestFirebaseBackup => false;

  double get totalTrailKm =>
      _trails.fold<double>(0.0, (sum, t) => sum + t.totalDistanceMeters) /
      1000.0;

  ExplorerProfile get explorerProfile => GamificationService.computeProfile(
        records: _records,
        trails: _trails,
        avatarSeed: prefs.avatarSeed,
      );

  Future<void> init() async {
    _wasOnline = connectivity.isOnline;
    connectivity.addListener(_handleConnectivityChange);
    sensors.addListener(_handleSensorUpdate);
    firebaseSync.addListener(_handleFirebaseAuthChange);

    await _loadPendingRemoteDeletes();
    await _loadPlaceLabelCache();
    await reload();

    // Never auto-start route recording on app launch: cleanly finalize any
    // stale trail left marked active from a previously closed/killed session.
    final staleActive = _trails.where((t) => t.isActive).toList();
    if (staleActive.isNotEmpty) {
      for (final trail in staleActive) {
        if (trail.points.isEmpty) {
          await db.deleteTrail(trail.id);
        } else {
          await db.upsertTrail(
            trail.copyWith(
              isActive: false,
              endedAt: trail.endedAt ?? trail.points.last.recordedAt,
            ),
          );
        }
      }
      _activeTrail = null;
      await reload();
    }

    if (connectivity.isOnline) {
      // ignore: unawaited_futures
      _guessPendingOfflineTrails();
      if (firebaseSync.canSyncNow) {
        // Automatically pull this user's private cloud data on startup
        // so switching devices (phone ↔ Desktop Web) stays in sync!
        // ignore: unawaited_futures
        pullFromFirebase();
      }
    }
  }

  void _handleFirebaseAuthChange() {
    notifyListeners();
  }

  void _handleConnectivityChange() {
    final nowOnline = connectivity.isOnline;
    if (nowOnline && !_wasOnline) {
      _failedPlaceLookupKeys.clear();
      // Back online! Automatically guess offline trails & pull cloud updates.
      // ignore: unawaited_futures
      _guessPendingOfflineTrails();
      if (firebaseSync.canSyncNow) {
        // ignore: unawaited_futures
        pullFromFirebase();
      }
    }
    _wasOnline = nowOnline;
    notifyListeners();
  }

  void _handleSensorUpdate() {
    final pos = sensors.currentPosition;
    if (pos != null && connectivity.isOnline && prefs.autoPrefetchOfflineTiles) {
      // Opportunistically cache OSM tiles around user while online so maps are
      // already available offline during a hike or walk!
      // ignore: unawaited_futures
      tiles.autoPrefetchSurrounding(
        lat: pos.latitude,
        lon: pos.longitude,
        isOnline: connectivity.isOnline,
      );
    }
  }

  void dismissFirebasePromptForSession() {
    notifyListeners();
  }

  Future<void> disableFirebaseBackupSuggestionsForever() async {
    await prefs.setSuggestFirebaseSync(false);
    notifyListeners();
  }

  Future<void> reload() async {
    _records = await db.getAllRecords();
    _trails = await db.getAllTrails();
    if (_activeTrail != null) {
      final refreshed = _trails.where((t) => t.id == _activeTrail!.id).toList();
      _activeTrail = refreshed.isNotEmpty ? refreshed.first : null;
    }
    notifyListeners();
  }

  /// Persists a camera/gallery photo (disk copy on Android, data URI on Web).
  Future<String> persistPickedPhotoFile(XFile picked) async {
    return persistPickedPhoto(picked, _uuid.v4());
  }

  Future<void> saveRecord(
    OsmRecord record, {
    bool markUnsynced = true,
    bool touchUpdatedAt = true,
  }) async {
    final toSave = record.copyWith(
      updatedAt: touchUpdatedAt ? DateTime.now() : record.updatedAt,
      clearFirebaseSyncedAt: markUnsynced,
    );
    await db.upsertRecord(toSave);
    await reload();
  }

  static String _placeGridKey(double lat, double lon) =>
      '${(lat * 1000).round()},${(lon * 1000).round()}';

  Future<void> _loadPlaceLabelCache() async {
    try {
      final settings = await db.getAllSettings();
      final raw = settings[_placeLabelCacheSettingKey];
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _placeLabelCache.clear();
          for (final entry in decoded.entries) {
            final v = entry.value?.toString().trim() ?? '';
            if (v.isNotEmpty) _placeLabelCache[entry.key.toString()] = v;
          }
        }
      }
    } catch (e) {
      debugPrint('[EdgeMapper] Could not load place label cache: $e');
    }
  }

  Future<void> _persistPlaceLabelCache() async {
    try {
      await db.setSetting(
        _placeLabelCacheSettingKey,
        jsonEncode(_placeLabelCache),
      );
    } catch (e) {
      debugPrint('[EdgeMapper] Could not persist place label cache: $e');
    }
  }

  /// Stores a resolved overall geographic place label (city, mountain,
  /// department/state, country) for a coordinate cell.
  void seedPlaceLabel(double lat, double lon, String label) {
    final clean = label.trim();
    if (clean.isEmpty) return;
    _placeLabelCache[_placeGridKey(lat, lon)] = clean;
    notifyListeners();
  }

  /// Returns a human-readable overall position for [record] (city, mountain,
  /// department/state, country) without showing raw GPS coordinates.
  /// When online and not yet cached, queues a throttled Nominatim lookup.
  String placeLabelForRecord(OsmRecord record) {
    final lat = record.effectiveLatitude;
    final lon = record.effectiveLongitude;
    final hasGps = lat.abs() >= 0.0001 || lon.abs() >= 0.0001;
    if (!hasGps) return 'No location';

    final key = _placeGridKey(lat, lon);
    final cached = _placeLabelCache[key];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    // Queue online reverse-geocode lookup if not already queued/failed
    if (connectivity.isOnline &&
        !_failedPlaceLookupKeys.contains(key) &&
        !_placeLookupQueue.any((e) => e.key == key)) {
      _placeLookupQueue.add((key: key, lat: lat, lon: lon));
      // ignore: unawaited_futures
      _drainPlaceLookupQueue();
    }

    // Check OSM address tags already present on the record
    final tagParts = <String>[];
    for (final k in const [
      'addr:city',
      'addr:suburb',
      'addr:county',
      'addr:state',
      'addr:province',
      'addr:country',
    ]) {
      final v = (record.tags[k] ?? '').trim();
      if (v.isNotEmpty &&
          !tagParts.any((p) => p.toLowerCase() == v.toLowerCase())) {
        tagParts.add(v);
      }
    }
    if (tagParts.isNotEmpty) {
      return tagParts.take(3).join(', ');
    }

    return LocationContextService.guessRegionOffline(lat, lon) ??
        'Unknown area';
  }

  Future<void> _drainPlaceLookupQueue() async {
    if (_isResolvingPlaceQueue) return;
    _isResolvingPlaceQueue = true;
    try {
      while (_placeLookupQueue.isNotEmpty && connectivity.isOnline) {
        final next = _placeLookupQueue.removeAt(0);
        if (_placeLabelCache.containsKey(next.key)) continue;
        final resolved = await LocationContextService.resolveOverallPlaceOnline(
          next.lat,
          next.lon,
        );
        if (resolved != null && resolved.isNotEmpty) {
          _placeLabelCache[next.key] = resolved;
          await _persistPlaceLabelCache();
          notifyListeners();
        } else {
          _failedPlaceLookupKeys.add(next.key);
        }
        if (_placeLookupQueue.isNotEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 1100));
        }
      }
    } finally {
      _isResolvingPlaceQueue = false;
    }
  }

  Future<void> _loadPendingRemoteDeletes() async {
    try {
      final settings = await db.getAllSettings();
      final rawRecs = settings[_pendingDeleteSettingKey];
      if (rawRecs != null && rawRecs.isNotEmpty) {
        final decoded = jsonDecode(rawRecs);
        if (decoded is List) {
          _pendingRemoteDeleteRecordIds
            ..clear()
            ..addAll(decoded.map((e) => e.toString()).where((e) => e.isNotEmpty));
        }
      }
      final rawTrails = settings[_pendingDeleteTrailSettingKey];
      if (rawTrails != null && rawTrails.isNotEmpty) {
        final decoded = jsonDecode(rawTrails);
        if (decoded is List) {
          _pendingRemoteDeleteTrailIds
            ..clear()
            ..addAll(decoded.map((e) => e.toString()).where((e) => e.isNotEmpty));
        }
      }
    } catch (e) {
      debugPrint('[EdgeMapper] Could not load pending remote deletes: $e');
    }
  }

  Future<void> _persistPendingRemoteDeletes() async {
    try {
      await db.setSetting(
        _pendingDeleteSettingKey,
        jsonEncode(_pendingRemoteDeleteRecordIds.toList()),
      );
      await db.setSetting(
        _pendingDeleteTrailSettingKey,
        jsonEncode(_pendingRemoteDeleteTrailIds.toList()),
      );
    } catch (e) {
      debugPrint('[EdgeMapper] Could not save pending remote deletes: $e');
    }
  }

  Future<({int recordsDeleted, int trailsDeleted, List<String> errors})>
      _flushPendingRemoteDeletes() async {
    if (pendingRemoteDeleteCount == 0 ||
        !connectivity.isOnline ||
        !firebaseSync.canSyncNow) {
      return (recordsDeleted: 0, trailsDeleted: 0, errors: const <String>[]);
    }
    int recordsDeleted = 0;
    int trailsDeleted = 0;
    final errors = <String>[];

    final recsToFlush = List<String>.from(_pendingRemoteDeleteRecordIds);
    for (final id in recsToFlush) {
      try {
        await firebaseSync.deleteRecord(id);
        _pendingRemoteDeleteRecordIds.remove(id);
        recordsDeleted++;
      } catch (e) {
        debugPrint('[EdgeMapper] Remote record delete failed for $id: $e');
        errors.add('Delete record $id: $e');
      }
    }

    final trailsToFlush = List<String>.from(_pendingRemoteDeleteTrailIds);
    for (final id in trailsToFlush) {
      try {
        await firebaseSync.deleteTrail(id);
        _pendingRemoteDeleteTrailIds.remove(id);
        trailsDeleted++;
      } catch (e) {
        debugPrint('[EdgeMapper] Remote trail delete failed for $id: $e');
        errors.add('Delete route $id: $e');
      }
    }

    await _persistPendingRemoteDeletes();
    return (
      recordsDeleted: recordsDeleted,
      trailsDeleted: trailsDeleted,
      errors: errors,
    );
  }

  Future<void> deleteRecord(String id) => deleteRecords([id]);

  /// Removes one or more records locally (including persisted photos and any
  /// pending batch diffs) and queues their Firestore removal so the Sync icon
  /// suggests syncing to delete them in the cloud too.
  Future<void> deleteRecords(Iterable<String> ids) async {
    final idSet = ids.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (idSet.isEmpty) return;

    for (final id in idSet) {
      final existing = _records.where((r) => r.id == id).toList();
      final wasSynced =
          existing.isNotEmpty && existing.first.isSyncedToFirebase;
      if (existing.isNotEmpty) {
        for (final path in existing.first.allPhotoPaths) {
          await deletePersistedPhoto(path);
        }
      }
      await db.deleteRecord(id);
      _pendingBatchDiffs =
          _pendingBatchDiffs.where((d) => d.before.id != id).toList();

      if (firebaseSync.isConfigured &&
          (firebaseSync.hasDeviceKey || firebaseSync.isSignedIn || wasSynced)) {
        _pendingRemoteDeleteRecordIds.add(id);
      }
    }

    await _persistPendingRemoteDeletes();
    await reload();
  }

  // --- Generalized Activity Route Recording ---

  /// Queries online OSM Nominatim for the current GPS location to auto-guess
  /// activity type (park stroll, city walk, mountain hike), route name, and tags.
  Future<LocationGuess?> guessCurrentLocationContext() async {
    if (!connectivity.isOnline) return null;
    final pos =
        sensors.currentPosition ?? await sensors.refreshCurrentPosition();
    if (pos == null) return null;
    final guess = await LocationContextService.guessFromCoordinatesOnline(
      pos.latitude,
      pos.longitude,
    );
    if (guess != null) {
      _lastLocationGuess = guess;
      notifyListeners();
    }
    return guess;
  }

  Future<HikeTrail> startTrail({
    required String name,
    ActivityType activityType = ActivityType.urbanWalk,
    Map<String, String>? tags,
    bool autoGuessLocation = true,
  }) async {
    if (_activeTrail != null) {
      await stopActiveTrail();
    }

    final currentPos =
        sensors.currentPosition ?? await sensors.refreshCurrentPosition();

    // Auto-guess activity type & route name when online if user left name blank
    LocationGuess? guess;
    bool needsDeferredGuess = !connectivity.isOnline;
    if (autoGuessLocation && connectivity.isOnline && currentPos != null) {
      guess = await LocationContextService.guessFromCoordinatesOnline(
        currentPos.latitude,
        currentPos.longitude,
      );
      if (guess != null) {
        _lastLocationGuess = guess;
        needsDeferredGuess = false;
      }
    }

    final resolvedActivity =
        (name.trim().isEmpty && guess != null) ? guess.activityType : activityType;
    final resolvedName = name.trim().isNotEmpty
        ? name.trim()
        : (guess?.suggestedRouteName ??
            '${resolvedActivity.shortLabel} ${DateTime.now().toIso8601String().substring(0, 16)}');

    final resolvedTags = Map<String, String>.from(
      tags ?? resolvedActivity.defaultTags,
    );
    if (tags == null && guess != null) {
      resolvedTags['highway'] = guess.highway;
      resolvedTags['surface'] = guess.surface;
    }

    final trail = HikeTrail(
      id: _uuid.v4(),
      name: resolvedName,
      startedAt: DateTime.now(),
      isActive: true,
      activityType: resolvedActivity,
      tags: resolvedTags,
      points: const [],
      needsLocationGuess: needsDeferredGuess,
      locationContext: guess?.locationContext ?? '',
    );

    await db.upsertTrail(trail);
    _activeTrail = trail;

    if (currentPos != null) {
      await _recordPointForTrail(trail.id, currentPos);
      // Pre-cache surrounding OSM tiles immediately while still online so the
      // map is already available offline if the user heads into a dead zone!
      if (connectivity.isOnline && prefs.autoPrefetchOfflineTiles) {
        // ignore: unawaited_futures
        tiles.autoPrefetchSurrounding(
          lat: currentPos.latitude,
          lon: currentPos.longitude,
          isOnline: true,
        );
      }
    }

    _attachTrailGpsStream(trail.id, trailName: trail.name);
    await reload();
    return _activeTrail ?? trail;
  }

  void _attachTrailGpsStream(String trailId, {String? trailName}) {
    _hikeGpsSub?.cancel();
    _hikeGpsSub = sensors
        .startHikeTrackStream(
          distanceFilterMeters: 5,
          trailName: trailName ?? _activeTrail?.name,
        )
        .listen(
      (position) async {
        if (_activeTrail?.id != trailId) return;
        await _recordPointForTrail(trailId, position);
      },
      onError: (Object err) {
        debugPrint('[EdgeMapper] Route GPS stream error: $err');
      },
    );
  }

  Future<void> _recordPointForTrail(String trailId, Position position) async {
    // Ignore very noisy fixes (>65m accuracy) if we already have points
    if (_activeTrail != null &&
        _activeTrail!.points.isNotEmpty &&
        position.accuracy > 65.0) {
      return;
    }

    final rawPoint = TrailPoint(
      trailId: trailId,
      latitude: position.latitude,
      longitude: position.longitude,
      altitudeMeters: position.altitude,
      accuracyMeters: position.accuracy,
      recordedAt: DateTime.now(),
    );
    final insertedId = await db.insertTrailPoint(rawPoint);
    final point = TrailPoint(
      id: insertedId,
      trailId: trailId,
      latitude: rawPoint.latitude,
      longitude: rawPoint.longitude,
      altitudeMeters: rawPoint.altitudeMeters,
      accuracyMeters: rawPoint.accuracyMeters,
      recordedAt: rawPoint.recordedAt,
    );

    if (_activeTrail?.id == trailId) {
      final updatedPoints = List<TrailPoint>.from(_activeTrail!.points)
        ..add(point);
      _activeTrail = _activeTrail!.copyWith(points: updatedPoints);
      final idx = _trails.indexWhere((t) => t.id == trailId);
      if (idx >= 0) {
        _trails = List<HikeTrail>.from(_trails)..[idx] = _activeTrail!;
      } else {
        _trails = [_activeTrail!, ..._trails];
      }
      notifyListeners();
    }
  }

  Future<void> addManualTrailWaypoint() async {
    final active = _activeTrail;
    if (active == null) return;
    final pos = await sensors.refreshCurrentPosition();
    if (pos != null) {
      await _recordPointForTrail(active.id, pos);
    }
  }

  Future<void> updateTrail(
    HikeTrail updated, {
    bool markUnsynced = true,
  }) async {
    final toSave = markUnsynced
        ? updated.copyWith(clearFirebaseSyncedAt: true)
        : updated;
    await db.upsertTrail(toSave);
    if (_activeTrail?.id == toSave.id) {
      _activeTrail = toSave;
    }
    await reload();
  }

  Future<void> updateActiveTrailTags(Map<String, String> tags) async {
    final active = _activeTrail;
    if (active == null) return;
    await updateTrail(active.copyWith(tags: tags));
  }

  Future<void> removeTrailPoint(String trailId, int pointId) async {
    await db.deleteTrailPoint(pointId);
    await reload();
  }

  /// Imports a GPS track recorded on an external Ham radio (NMEA-0183, APRS
  /// TNC2/Mic-E, GPX, KML, or CSV) as a saved route ready to inspect, clean,
  /// tag, export, or publish to OpenStreetMap.
  Future<HikeTrail> importExternalGpsTrail({
    required ImportedGpsTrackResult parsed,
    String? customName,
    ActivityType activityType = ActivityType.hiking,
    Map<String, String>? tags,
    String? selectedCallsign,
  }) async {
    if (parsed.points.isEmpty) {
      throw StateError('No valid GPS track points to import.');
    }

    final trailId = _uuid.v4();
    final points = parsed.points.map((p) => p.toTrailPoint(trailId)).toList();
    final startedAt = parsed.startedAt ?? DateTime.now();
    final endedAt = parsed.endedAt ?? startedAt;

    final resolvedName = (customName != null && customName.trim().isNotEmpty)
        ? customName.trim()
        : parsed.suggestedName;

    final resolvedTags = Map<String, String>.from(
      tags ?? activityType.defaultTags,
    );
    resolvedTags['source'] = OsmTagStandards.recommendedSource();

    final callPart =
        (selectedCallsign != null && selectedCallsign.trim().isNotEmpty)
            ? ' · ${selectedCallsign.trim().toUpperCase()}'
            : (parsed.callsigns.length == 1 ? ' · ${parsed.callsigns.first}' : '');
    final contextLabel = 'Ham Radio GPS (${parsed.format.shortLabel}$callPart)';

    final trail = HikeTrail(
      id: trailId,
      name: resolvedName,
      startedAt: startedAt,
      endedAt: endedAt,
      isActive: false,
      activityType: activityType,
      tags: resolvedTags,
      points: points,
      needsLocationGuess: false,
      locationContext: contextLabel,
    );

    await db.upsertTrail(trail);
    await db.replaceTrailPoints(trailId, points);
    await reload();

    if (connectivity.isOnline &&
        prefs.autoPrefetchOfflineTiles &&
        points.isNotEmpty) {
      // ignore: unawaited_futures
      tiles.autoPrefetchSurrounding(
        lat: points.first.latitude,
        lon: points.first.longitude,
        isOnline: true,
      );
    }

    return _trails.firstWhere((t) => t.id == trailId, orElse: () => trail);
  }

  Future<HikeTrail?> stopActiveTrail() async {
    await _hikeGpsSub?.cancel();
    _hikeGpsSub = null;
    await sensors.stopHikeTrackStream();
    final active = _activeTrail;
    if (active != null) {
      var finished = active.copyWith(
        isActive: false,
        endedAt: DateTime.now(),
        clearFirebaseSyncedAt: true,
      );
      await db.upsertTrail(finished);
      _activeTrail = null;
      await reload();

      // If recorded while offline, flag so when user returns online we guess it;
      // if online and still unnamed/needs guess, guess immediately!
      if (finished.needsLocationGuess && connectivity.isOnline) {
        final guessed = await guessTrailLocation(finished);
        if (guessed != null) finished = guessed;
      }
      return finished;
    }
    return null;
  }

  Future<void> deleteTrail(String trailId) => deleteTrails([trailId]);

  /// Removes one or more routes locally and queues their Firestore removal so
  /// the Sync icon suggests syncing to delete them in the cloud too.
  Future<void> deleteTrails(Iterable<String> ids) async {
    final idSet = ids.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (idSet.isEmpty) return;

    bool queuedAny = false;
    for (final trailId in idSet) {
      final existing = _trails.where((t) => t.id == trailId).toList();
      final wasSynced =
          existing.isNotEmpty && existing.first.isSyncedToFirebase;
      if (_activeTrail?.id == trailId) {
        await _hikeGpsSub?.cancel();
        _hikeGpsSub = null;
        await sensors.stopHikeTrackStream();
        _activeTrail = null;
      }
      await db.deleteTrail(trailId);
      if (firebaseSync.isConfigured &&
          (firebaseSync.hasDeviceKey || firebaseSync.isSignedIn || wasSynced)) {
        _pendingRemoteDeleteTrailIds.add(trailId);
        queuedAny = true;
      }
    }
    if (queuedAny) {
      await _persistPendingRemoteDeletes();
    }
    await reload();
  }

  /// Auto-guesses route location context, activity type, and name for a trail
  /// (used on-demand or automatically when the device goes back online).
  Future<HikeTrail?> guessTrailLocation(HikeTrail trail) async {
    if (!connectivity.isOnline || trail.points.isEmpty) return null;
    final midPt = trail.points[trail.points.length ~/ 2];
    final guess = await LocationContextService.guessFromCoordinatesOnline(
      midPt.latitude,
      midPt.longitude,
    );
    if (guess == null) return null;

    final isGenericName = trail.name.startsWith('Trail ') ||
        trail.name.startsWith('Hike ') ||
        trail.name.startsWith('City Walk ') ||
        trail.name.startsWith('Park ') ||
        trail.name.startsWith('Walk ');

    final nextTags = Map<String, String>.from(trail.tags);
    nextTags.putIfAbsent('highway', () => guess.highway);
    nextTags.putIfAbsent('surface', () => guess.surface);

    final updated = trail.copyWith(
      name: isGenericName ? guess.suggestedRouteName : trail.name,
      activityType: isGenericName ? guess.activityType : trail.activityType,
      tags: nextTags,
      needsLocationGuess: false,
      locationContext: guess.locationContext,
      clearFirebaseSyncedAt: true,
    );
    await db.upsertTrail(updated);
    await reload();
    return updated;
  }

  Future<void> _guessPendingOfflineTrails() async {
    final pending =
        _trails.where((t) => t.needsLocationGuess && t.points.isNotEmpty).toList();
    for (final trail in pending) {
      await guessTrailLocation(trail);
    }
  }

  // --- Batch Cloud Enrichment Proposals (for Diff Review) ---

  void cancelBatchEnrichment() {
    if (!_isEnrichingBatch) return;
    _cancelBatchRequested = true;
    ai.cancelActiveLocalNano();
    _batchEnrichStatus = 'Stopping after current step...';
    notifyListeners();
  }

  void removePendingBatchDiff(String recordId) {
    final beforeLen = _pendingBatchDiffs.length;
    _pendingBatchDiffs =
        _pendingBatchDiffs.where((d) => d.before.id != recordId).toList();
    if (_pendingBatchDiffs.length != beforeLen) {
      notifyListeners();
    }
  }

  void clearPendingBatchDiffs() {
    if (_pendingBatchDiffs.isEmpty) return;
    _pendingBatchDiffs = [];
    notifyListeners();
  }

  /// Applies every remaining diff in [pendingBatchDiffs] and bumps `updatedAt`
  /// so all newly updated records immediately appear at the top of All Records.
  Future<int> applyAllPendingBatchDiffs() async {
    if (_pendingBatchDiffs.isEmpty) return 0;
    final toApply = List<EnrichmentDiff>.from(_pendingBatchDiffs);
    final baseNow = DateTime.now();
    for (int i = 0; i < toApply.length; i++) {
      final diff = toApply[i];
      // Assign monotonically increasing timestamps so all newly updated records
      // rise cleanly to the top of the Records list.
      final updatedRecord = diff.proposed.copyWith(
        updatedAt: baseNow.add(Duration(milliseconds: i)),
        clearFirebaseSyncedAt: true,
      );
      await db.upsertRecord(updatedRecord);
    }
    _pendingBatchDiffs = [];
    await reload();
    return toApply.length;
  }

  Future<List<EnrichmentDiff>> generateBatchEnrichmentDiffs({
    AiUpdateMode mode = AiUpdateMode.enrichMerge,
    bool forceCloud = false,
  }) async {
    if (_isEnrichingBatch || !ai.canEnrichRecords) return const [];

    final drafts = offlineDraftRecords;
    if (drafts.isEmpty) return const [];

    final useLocalNano = !forceCloud && ai.willEnrichUseNanoFirst;

    _isEnrichingBatch = true;
    _batchEnrichDone = 0;
    _batchEnrichTotal = drafts.length;
    _batchEnrichSucceeded = 0;
    _batchEnrichFailed = 0;
    _cancelBatchRequested = false;
    _lastBatchEnrichError = null;
    _batchEnrichStatus = 'Analyzing 1/${drafts.length}...';
    notifyListeners();

    final results = List<EnrichmentDiff?>.filled(drafts.length, null);
    bool throttled = false;

    Future<void> processIndex(int index) async {
      if (_cancelBatchRequested) return;
      final draft = drafts[index];
      final activeModel =
          useLocalNano ? 'Nano 4' : ai.effectiveGeminiModelNow;
      _batchEnrichStatus =
          'Analyzing ${_batchEnrichDone + 1}/${drafts.length} ($activeModel)...';
      notifyListeners();

      try {
        final diff = await ai.proposeAiUpdate(
          draft,
          mode: mode,
          forceCloud: forceCloud,
          shouldCancel: () => _cancelBatchRequested,
          onStatusUpdate: (status) {
            _batchEnrichStatus = '${index + 1}/${drafts.length}: $status';
            notifyListeners();
          },
        );
        results[index] = diff;
        _batchEnrichSucceeded++;
      } on AiBatchCancelledException {
        return;
      } catch (e) {
        _batchEnrichFailed++;
        if (HybridAiService.isTransientCloudError(e)) {
          throttled = true;
        }
        _lastBatchEnrichError = HybridAiService.formatCloudError(e);
        debugPrint(
          '[EdgeMapper] Failed to propose AI update for ${draft.id}: $e',
        );
      }
      _batchEnrichDone++;
      notifyListeners();
    }

    try {
      // Warm up on photo 1 first so any immediate model failover / cooldown
      // applies cleanly before launching the 2-worker parallel pool.
      await processIndex(0);

      if (drafts.length > 1 && !_cancelBatchRequested) {
        int nextIndex = 1;
        Future<void> runWorker({required bool isSecondary}) async {
          if (isSecondary) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          while (!_cancelBatchRequested) {
            if (isSecondary && throttled) break;
            if (nextIndex >= drafts.length) break;
            final current = nextIndex++;
            await processIndex(current);
            if (_cancelBatchRequested) break;
            if (throttled) {
              await Future<void>.delayed(const Duration(milliseconds: 800));
            }
          }
        }

        await Future.wait([
          runWorker(isSecondary: false),
          if (!useLocalNano && !throttled && drafts.length > 2)
            runWorker(isSecondary: true),
        ]);
      }
    } finally {
      _isEnrichingBatch = false;
      _batchEnrichStatus = '';
    }
    final completedDiffs = results.whereType<EnrichmentDiff>().toList();
    if (completedDiffs.isNotEmpty) {
      _pendingBatchDiffs = completedDiffs;
    }
    notifyListeners();
    return completedDiffs;
  }

  // --- Firebase Cloud Sync ---

  /// Pulls records (including embedded photos) and trails from the signed-in
  /// user's private Firestore space (`/users/{uid}/...`), merging cleanly into
  /// local storage without overwriting newer unsynced edits.
  Future<FirebaseSyncResult> pullFromFirebase() async {
    if (_isSyncingFirebase || !connectivity.isOnline || !firebaseSync.canSyncNow) {
      return const FirebaseSyncResult(recordsSynced: 0, trailsSynced: 0);
    }

    _isSyncingFirebase = true;
    notifyListeners();

    int recordsPulled = 0;
    int trailsPulled = 0;
    final errors = <String>[];

    try {
      final pull = await _pullInternal();
      recordsPulled = pull.recordsPulled;
      trailsPulled = pull.trailsPulled;
      errors.addAll(pull.errors);
    } finally {
      _isSyncingFirebase = false;
      await reload();
    }

    return FirebaseSyncResult(
      recordsSynced: 0,
      trailsSynced: 0,
      recordsPulled: recordsPulled,
      trailsPulled: trailsPulled,
      errors: errors,
    );
  }

  Future<
      ({
        int recordsPulled,
        int trailsPulled,
        Set<String> remoteRecordIds,
        Set<String> remoteTrailIds,
        Set<String> remoteIdsMissingPhoto,
        bool pullRecordsSucceeded,
        bool pullTrailsSucceeded,
        List<String> errors,
      })> _pullInternal() async {
    int recordsPulled = 0;
    int trailsPulled = 0;
    final remoteRecordIds = <String>{};
    final remoteTrailIds = <String>{};
    final remoteIdsMissingPhoto = <String>{};
    bool pullRecordsSucceeded = false;
    bool pullTrailsSucceeded = false;
    final errors = <String>[];
    final localRecordsById = {for (final r in _records) r.id: r};
    final localTrailsById = {for (final t in _trails) t.id: t};

    try {
      final remoteRecords = await firebaseSync.fetchAllRecords();
      pullRecordsSucceeded = true;
      for (final remoteItem in remoteRecords) {
        final remote = remoteItem.record;
        if (_pendingRemoteDeleteRecordIds.contains(remote.id)) continue;
        remoteRecordIds.add(remote.id);
        final local = localRecordsById[remote.id];
        final remoteHasPhoto = remoteItem.photoDataUri != null &&
            remoteItem.photoDataUri!.isNotEmpty;
        if (!remoteHasPhoto) {
          remoteIdsMissingPhoto.add(remote.id);
        }

        // Keep newer unsynced local edits so Step B pushes them instead of overwriting,
        // but still restore a missing photo from Firestore if remote has one!
        if (local != null &&
            !local.isSyncedToFirebase &&
            local.updatedAt.isAfter(remote.updatedAt)) {
          if (!photoExists(local.photoPath) && remoteHasPhoto) {
            final restoredPath = await restorePhotoFromDataUri(
              remoteItem.photoDataUri!,
              remote.id,
            );
            if (restoredPath != null) {
              await db.upsertRecord(local.copyWith(photoPath: restoredPath));
              recordsPulled++;
            }
          }
          continue;
        }

        final shouldSave = local == null ||
            remote.updatedAt.isAfter(local.updatedAt) ||
            (!photoExists(local.photoPath) && remoteHasPhoto);

        if (!shouldSave) continue;

        String? resolvedPhotoPath =
            (local != null && photoExists(local.photoPath))
                ? local.photoPath
                : null;
        if (resolvedPhotoPath == null && remoteHasPhoto) {
          resolvedPhotoPath = await restorePhotoFromDataUri(
            remoteItem.photoDataUri!,
            remote.id,
          );
        }

        await db.upsertRecord(
          remote.copyWith(photoPath: resolvedPhotoPath),
        );
        recordsPulled++;
      }
    } catch (e) {
      debugPrint('[EdgeMapper] Pull records error: $e');
      errors.add('Pull records: $e');
    }

    try {
      final remoteTrails = await firebaseSync.fetchAllTrails();
      pullTrailsSucceeded = true;
      for (final remote in remoteTrails) {
        if (_pendingRemoteDeleteTrailIds.contains(remote.id)) continue;
        remoteTrailIds.add(remote.id);
        final local = localTrailsById[remote.id];
        if (local != null && local.isActive) continue;
        if (local != null &&
            !local.isSyncedToFirebase &&
            local.points.length >= remote.points.length) {
          continue;
        }

        final shouldSave = local == null ||
            remote.points.length > local.points.length ||
            remote.name != local.name;

        if (!shouldSave) continue;

        await db.upsertTrail(remote);
        await db.replaceTrailPoints(remote.id, remote.points);
        trailsPulled++;
      }
    } catch (e) {
      debugPrint('[EdgeMapper] Pull trails error: $e');
      errors.add('Pull trails: $e');
    }

    return (
      recordsPulled: recordsPulled,
      trailsPulled: trailsPulled,
      remoteRecordIds: remoteRecordIds,
      remoteTrailIds: remoteTrailIds,
      remoteIdsMissingPhoto: remoteIdsMissingPhoto,
      pullRecordsSucceeded: pullRecordsSucceeded,
      pullTrailsSucceeded: pullTrailsSucceeded,
      errors: errors,
    );
  }

  /// Full automatic two-way E2EE Firebase sync:
  /// 1. Migrates & purges any legacy plaintext documents.
  /// 2. Pulls remote encrypted records, photos & routes from Firestore `items/`.
  /// 3. Automatically detects any local records, photos, or finished routes that
  ///    are either modified locally OR not yet present in Firestore, and uploads
  ///    only those encrypted items — no manual "re-upload all" button needed.
  Future<FirebaseSyncResult> syncAllUnsyncedToFirebase({
    bool forceUploadAll = false,
  }) async {
    if (_isSyncingFirebase) {
      return const FirebaseSyncResult(recordsSynced: 0, trailsSynced: 0);
    }
    if (!connectivity.isOnline) {
      return const FirebaseSyncResult(
        recordsSynced: 0,
        trailsSynced: 0,
        errors: ['Device is offline.'],
      );
    }
    if (!firebaseSync.isConfigured) {
      return const FirebaseSyncResult(
        recordsSynced: 0,
        trailsSynced: 0,
        errors: ['Firebase is not configured in this build.'],
      );
    }
    if (!firebaseSync.isSignedIn || !firebaseSync.isVaultUnlocked) {
      return const FirebaseSyncResult(
        recordsSynced: 0,
        trailsSynced: 0,
        errors: ['Unlock Cloud Sync first.'],
      );
    }

    _isSyncingFirebase = true;
    notifyListeners();

    int recordsOk = 0;
    int trailsOk = 0;
    int recordsPulled = 0;
    int trailsPulled = 0;
    int recordsDeleted = 0;
    int trailsDeleted = 0;
    int photosOk = 0;
    final errors = <String>[];

    try {
      // 0a. Flush locally removed records & routes so they are deleted on Firestore
      final flushed = await _flushPendingRemoteDeletes();
      recordsDeleted = flushed.recordsDeleted;
      trailsDeleted = flushed.trailsDeleted;
      errors.addAll(flushed.errors);

      // 0b. Migrate & purge any leftover legacy plaintext docs from users/{uid}/osm_records & trails
      //     into E2EE items/{itemId} before pulling & pushing.
      try {
        await firebaseSync.migrateAndPurgeLegacyPlaintextCollections();
      } catch (e) {
        debugPrint('[EdgeMapper] Legacy plaintext migration skipped: $e');
      }

      // 1. Pull remote updates first and inspect which items already exist in Firestore
      final pull = await _pullInternal();
      recordsPulled = pull.recordsPulled;
      trailsPulled = pull.trailsPulled;
      errors.addAll(pull.errors);

      _records = await db.getAllRecords();
      _trails = await db.getAllTrails();

      // 2. Automatically push:
      //    - unsynced/edited local records
      //    - local records that Firestore does NOT yet contain
      //    - local records whose Firestore copy is missing their photo
      final recordsToPush = <OsmRecord>[];
      final queuedIds = <String>{};
      for (final record in _records) {
        final missingInCloud = pull.pullRecordsSucceeded &&
            !pull.remoteRecordIds.contains(record.id);
        final missingPhotoInCloud =
            pull.remoteIdsMissingPhoto.contains(record.id) &&
                photoExists(record.photoPath);
        if (forceUploadAll ||
            !record.isSyncedToFirebase ||
            missingInCloud ||
            missingPhotoInCloud) {
          if (queuedIds.add(record.id)) {
            recordsToPush.add(record);
          }
        }
      }

      final trailsToPush = _trails.where((t) {
        if (t.isActive) return false;
        final missingInCloud =
            pull.pullTrailsSucceeded && !pull.remoteTrailIds.contains(t.id);
        return forceUploadAll || !t.isSyncedToFirebase || missingInCloud;
      }).toList();

      final now = DateTime.now().toUtc();
      // Bounded parallel uploads (chunks of 3) for fast cross-device sync
      // while staying within Pixel 6a memory limits.
      const batchSize = 3;
      for (int i = 0; i < recordsToPush.length; i += batchSize) {
        final chunk = recordsToPush.sublist(
          i,
          (i + batchSize) > recordsToPush.length
              ? recordsToPush.length
              : i + batchSize,
        );
        await Future.wait(
          chunk.map((record) async {
            try {
              final uploadedPhoto = await firebaseSync.syncRecord(record);
              if (uploadedPhoto) photosOk++;
              await db.upsertRecord(record.copyWith(firebaseSyncedAt: now));
              recordsOk++;
            } catch (e) {
              errors.add('Record "${record.displayName}": $e');
            }
          }),
        );
      }
      for (int i = 0; i < trailsToPush.length; i += batchSize) {
        final chunk = trailsToPush.sublist(
          i,
          (i + batchSize) > trailsToPush.length
              ? trailsToPush.length
              : i + batchSize,
        );
        await Future.wait(
          chunk.map((trail) async {
            try {
              await firebaseSync.syncTrail(trail);
              await db.upsertTrail(trail.copyWith(firebaseSyncedAt: now));
              trailsOk++;
            } catch (e) {
              errors.add('Route "${trail.name}": $e');
            }
          }),
        );
      }
    } finally {
      _isSyncingFirebase = false;
      await reload();
    }

    return FirebaseSyncResult(
      recordsSynced: recordsOk,
      trailsSynced: trailsOk,
      recordsPulled: recordsPulled,
      trailsPulled: trailsPulled,
      recordsDeleted: recordsDeleted,
      trailsDeleted: trailsDeleted,
      photosSynced: photosOk,
      errors: errors,
    );
  }

  Future<void> syncSingleRecordToFirebase(OsmRecord record) async {
    await firebaseSync.syncRecord(record);
    await db.upsertRecord(
      record.copyWith(firebaseSyncedAt: DateTime.now().toUtc()),
    );
    await reload();
  }

  Future<void> syncSingleTrailToFirebase(HikeTrail trail) async {
    await firebaseSync.syncTrail(trail);
    await db.upsertTrail(
      trail.copyWith(firebaseSyncedAt: DateTime.now().toUtc()),
    );
    await reload();
  }

  /// Permanently deletes ALL records, photos, and routes stored in Cloud
  /// Firestore under this user's UID while keeping 100% of local data intact
  /// (and marking local items as local-only).
  Future<CloudWipeResult> deleteAllCloudDataKeepLocal() async {
    if (_isSyncingFirebase) {
      return const CloudWipeResult(
        recordsDeleted: 0,
        trailsDeleted: 0,
        errors: ['Sync is currently in progress. Wait a moment and try again.'],
      );
    }
    if (!connectivity.isOnline) {
      return const CloudWipeResult(
        recordsDeleted: 0,
        trailsDeleted: 0,
        errors: ['Device is offline. Go online to delete Firestore cloud data.'],
      );
    }
    if (!firebaseSync.isConfigured || !firebaseSync.isSignedIn) {
      return const CloudWipeResult(
        recordsDeleted: 0,
        trailsDeleted: 0,
        errors: ['Activate or unlock your Private Sync Key first.'],
      );
    }

    _isSyncingFirebase = true;
    notifyListeners();
    try {
      final result = await firebaseSync.deleteAllCloudData();
      _pendingRemoteDeleteRecordIds.clear();
      _pendingRemoteDeleteTrailIds.clear();
      await _persistPendingRemoteDeletes();

      // Mark all local records & trails as local-only (keep all local data & photos intact!)
      for (final record in _records) {
        if (record.isSyncedToFirebase) {
          await db.upsertRecord(record.copyWith(clearFirebaseSyncedAt: true));
        }
      }
      for (final trail in _trails) {
        if (trail.isSyncedToFirebase) {
          await db.upsertTrail(trail.copyWith(clearFirebaseSyncedAt: true));
        }
      }
      return result;
    } finally {
      _isSyncingFirebase = false;
      await reload();
    }
  }

  @override
  void dispose() {
    connectivity.removeListener(_handleConnectivityChange);
    sensors.removeListener(_handleSensorUpdate);
    firebaseSync.removeListener(_handleFirebaseAuthChange);
    _hikeGpsSub?.cancel();
    super.dispose();
  }
}
