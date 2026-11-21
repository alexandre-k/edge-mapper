import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/hike_trail.dart';
import 'app_env_config.dart';
import 'connectivity_service.dart';
import 'explorer_avatar_service.dart';
import 'firebase_sync_service.dart';
import 'gamification_service.dart';
import 'local_db_service.dart';
import 'user_preferences_service.dart';

class LeaderboardEntry {
  final String explorerId;

  /// Real OpenStreetMap username (or current user's display handle if not signed in to OSM).
  final String displayName;
  final String funnyNickname;
  final String avatarSeed;
  final int level;
  final int xp;

  /// Number of mapped edits/objects near the POI (OSM `changes_count` sum, or local POIs).
  final int recordsCount;
  final double trailsKm;
  final int verifiedProofsCount;
  final bool isCurrentUser;
  final bool isCommunitySynced;
  final int rank;

  // Real OpenStreetMap profile & local mapping metrics
  final int? osmUserId;
  final int osmAreaChangesCount;
  final int osmAreaChangesetsCount;
  final int osmLifetimeChangesets;
  final int osmTracesCount;
  final double? distanceToPoiMeters;
  final DateTime? lastMappedAt;
  final DateTime? osmAccountCreatedAt;
  final String? osmProfileUrl;

  const LeaderboardEntry({
    required this.explorerId,
    required this.displayName,
    required this.funnyNickname,
    required this.avatarSeed,
    required this.level,
    required this.xp,
    required this.recordsCount,
    required this.trailsKm,
    required this.verifiedProofsCount,
    required this.isCurrentUser,
    this.isCommunitySynced = false,
    this.rank = 0,
    this.osmUserId,
    this.osmAreaChangesCount = 0,
    this.osmAreaChangesetsCount = 0,
    this.osmLifetimeChangesets = 0,
    this.osmTracesCount = 0,
    this.distanceToPoiMeters,
    this.lastMappedAt,
    this.osmAccountCreatedAt,
    this.osmProfileUrl,
  });

  bool get isRealOsmProfile => osmUserId != null && osmUserId! > 0;

  String get effectiveOsmProfileUrl =>
      osmProfileUrl ??
      (isRealOsmProfile
          ? 'https://www.openstreetmap.org/user/${Uri.encodeComponent(displayName)}'
          : '');

  LeaderboardEntry withRank(int newRank) => LeaderboardEntry(
        explorerId: explorerId,
        displayName: displayName,
        funnyNickname: funnyNickname,
        avatarSeed: avatarSeed,
        level: level,
        xp: xp,
        recordsCount: recordsCount,
        trailsKm: trailsKm,
        verifiedProofsCount: verifiedProofsCount,
        isCurrentUser: isCurrentUser,
        isCommunitySynced: isCommunitySynced,
        rank: newRank,
        osmUserId: osmUserId,
        osmAreaChangesCount: osmAreaChangesCount,
        osmAreaChangesetsCount: osmAreaChangesetsCount,
        osmLifetimeChangesets: osmLifetimeChangesets,
        osmTracesCount: osmTracesCount,
        distanceToPoiMeters: distanceToPoiMeters,
        lastMappedAt: lastMappedAt,
        osmAccountCreatedAt: osmAccountCreatedAt,
        osmProfileUrl: osmProfileUrl,
      );

  Map<String, dynamic> toCacheJson() => {
        'explorerId': explorerId,
        'displayName': displayName,
        'funnyNickname': funnyNickname,
        'avatarSeed': avatarSeed,
        'level': level,
        'xp': xp,
        'recordsCount': recordsCount,
        'trailsKm': trailsKm,
        'verifiedProofsCount': verifiedProofsCount,
        'osmUserId': osmUserId,
        'osmAreaChangesCount': osmAreaChangesCount,
        'osmAreaChangesetsCount': osmAreaChangesetsCount,
        'osmLifetimeChangesets': osmLifetimeChangesets,
        'osmTracesCount': osmTracesCount,
        'distanceToPoiMeters': distanceToPoiMeters,
        'lastMappedAt': lastMappedAt?.toUtc().toIso8601String(),
        'osmAccountCreatedAt': osmAccountCreatedAt?.toUtc().toIso8601String(),
        'osmProfileUrl': osmProfileUrl,
      };

  static LeaderboardEntry? fromCacheJson(Map<String, dynamic> m) {
    final id = m['explorerId']?.toString() ?? '';
    final name = m['displayName']?.toString() ?? '';
    if (id.isEmpty || name.isEmpty) return null;
    final xp = (m['xp'] as num?)?.toInt() ?? 0;
    final lv = (m['level'] as num?)?.toInt() ?? GamificationService.levelForXp(xp);
    return LeaderboardEntry(
      explorerId: id,
      displayName: name,
      funnyNickname: m['funnyNickname']?.toString() ?? 'Mapper',
      avatarSeed: m['avatarSeed']?.toString() ?? id,
      level: lv,
      xp: xp,
      recordsCount: (m['recordsCount'] as num?)?.toInt() ?? 0,
      trailsKm: (m['trailsKm'] as num?)?.toDouble() ?? 0.0,
      verifiedProofsCount: (m['verifiedProofsCount'] as num?)?.toInt() ?? 0,
      isCurrentUser: false,
      isCommunitySynced: true,
      osmUserId: (m['osmUserId'] as num?)?.toInt(),
      osmAreaChangesCount: (m['osmAreaChangesCount'] as num?)?.toInt() ?? 0,
      osmAreaChangesetsCount:
          (m['osmAreaChangesetsCount'] as num?)?.toInt() ?? 0,
      osmLifetimeChangesets:
          (m['osmLifetimeChangesets'] as num?)?.toInt() ?? 0,
      osmTracesCount: (m['osmTracesCount'] as num?)?.toInt() ?? 0,
      distanceToPoiMeters: (m['distanceToPoiMeters'] as num?)?.toDouble(),
      lastMappedAt: DateTime.tryParse(m['lastMappedAt']?.toString() ?? ''),
      osmAccountCreatedAt:
          DateTime.tryParse(m['osmAccountCreatedAt']?.toString() ?? ''),
      osmProfileUrl: m['osmProfileUrl']?.toString(),
    );
  }
}

class LeaderboardSnapshot {
  final List<LeaderboardEntry> entries;
  final LeaderboardEntry currentUser;
  final int currentUserRank;
  final int totalMappers;
  final int percentileTop; // e.g. Top 25%
  final LeaderboardEntry? nextRivalAbove;
  final int xpToNextRank;
  final String standingLabel;
  final String incentiveMessage;
  final bool syncedWithCloud;
  final String? anchorLabel;
  final double? anchorLatitude;
  final double? anchorLongitude;
  final double radiusMeters;
  final DateTime? lastFetchedAt;
  final String? lastError;

  const LeaderboardSnapshot({
    required this.entries,
    required this.currentUser,
    required this.currentUserRank,
    required this.totalMappers,
    required this.percentileTop,
    required this.nextRivalAbove,
    required this.xpToNextRank,
    required this.standingLabel,
    required this.incentiveMessage,
    required this.syncedWithCloud,
    this.anchorLabel,
    this.anchorLatitude,
    this.anchorLongitude,
    this.radiusMeters = 2000,
    this.lastFetchedAt,
    this.lastError,
  });

  bool get isFirst => currentUserRank == 1;
  bool get isLast => currentUserRank == totalMappers;
  bool get hasRealOsmMappers =>
      entries.any((e) => !e.isCurrentUser && e.isRealOsmProfile);
}

class _OsmAreaAccumulator {
  final int uid;
  String username;
  int areaChanges = 0;
  int areaChangesets = 0;
  double nearestDistanceMeters = double.infinity;
  DateTime? lastMappedAt;

  _OsmAreaAccumulator({
    required this.uid,
    required this.username,
  });
}

class _OsmUserProfileStats {
  final int uid;
  final String displayName;
  final int lifetimeChangesets;
  final int tracesCount;
  final DateTime? accountCreatedAt;

  const _OsmUserProfileStats({
    required this.uid,
    required this.displayName,
    required this.lifetimeChangesets,
    required this.tracesCount,
    this.accountCreatedAt,
  });
}

/// Manages real OpenStreetMap local Guild Rankings anchored around a Point of
/// Interest (or current GPS location):
/// - Fetches real OpenStreetMap contributors who mapped near the POI via
///   official OSM API v0.6 (`changesets.json?bbox=...` + `users.json?users=...`).
/// - Filters out giant continental/automated edits so only local mappers near
///   the POI appear.
/// - Computes Experience (XP) directly from real mapped volume on OpenStreetMap
///   (real edits, local changesets, lifetime changesets, and GPS traces).
/// - Uses 100% real OpenStreetMap usernames and links to real OSM profiles —
///   zero fictional benchmark accounts.
class LeaderboardService extends ChangeNotifier {
  static const String _cacheSettingsKey = 'osm_leaderboard_cache_v1';
  static const String _osmApiBase = 'https://api.openstreetmap.org';
  static String get _userAgent =>
      AppEnvConfig.httpUserAgent(component: 'Leaderboard');

  /// Maximum changeset bounding-box span (in degrees, ~35 km) considered "local"
  /// to the POI; wider bounding boxes are nationwide/global armchair edits.
  static const double maxLocalChangesetSpanDeg = 0.35;

  final UserPreferencesService prefs;
  final FirebaseSyncService firebaseSync;
  final ConnectivityService connectivity;
  final LocalDbService? _db;
  final http.Client _client;

  List<LeaderboardEntry> _osmEntries = const [];
  _OsmUserProfileStats? _currentUserOsmStats;
  bool _isRefreshing = false;
  bool _hasSyncedOsm = false;
  String? _anchorLabel;
  double? _anchorLat;
  double? _anchorLon;
  double _radiusMeters = 2000;
  DateTime? _lastFetchedAt;
  String? _lastError;

  LeaderboardService({
    required this.prefs,
    required this.firebaseSync,
    required this.connectivity,
    LocalDbService? db,
    http.Client? client,
  })  : _db = db,
        _client = client ?? http.Client();

  bool get isRefreshing => _isRefreshing;
  bool get hasSyncedRemote => _hasSyncedOsm;
  String? get anchorLabel => _anchorLabel;
  double? get anchorLatitude => _anchorLat;
  double? get anchorLongitude => _anchorLon;
  double get radiusMeters => _radiusMeters;
  DateTime? get lastFetchedAt => _lastFetchedAt;
  String? get lastError => _lastError;

  /// Computes Experience (XP) directly from real OpenStreetMap mapping numbers:
  /// - 5 XP per real OSM object edit (`changes_count`) mapped near the POI
  /// - 20 XP per local changeset submitted near the POI
  /// - 2 XP per lifetime OSM changeset (capped at 2,500 so local mapping stays prominent)
  /// - 10 XP per uploaded OSM GPS trace (capped at 200)
  static int computeRealOsmXp({
    required int areaChangesCount,
    required int areaChangesetsCount,
    int lifetimeChangesetsCount = 0,
    int tracesCount = 0,
  }) {
    final localEditsXp = math.max(0, areaChangesCount) * 5;
    final localChangesetsXp = math.max(0, areaChangesetsCount) * 20;
    final profileChangesetsXp =
        math.min(math.max(0, lifetimeChangesetsCount), 2500) * 2;
    final tracesXp = math.min(math.max(0, tracesCount), 200) * 10;
    return localEditsXp + localChangesetsXp + profileChangesetsXp + tracesXp;
  }

  /// Formats a distance from a POI cleanly (`240 m` or `1.4 km`).
  static String formatDistanceFromPoi(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000.0).toStringAsFixed(1)} km';
  }

  /// Restores the last cached real OpenStreetMap local leaderboard from SQLite
  /// so offline sessions still display real OSM contributors near the last POI.
  Future<void> init() async {
    final db = _db;
    if (db == null) return;
    try {
      final all = await db.getAllSettings();
      final raw = all[_cacheSettingsKey];
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final rawList = decoded['entries'] as List? ?? const [];
      final restored = <LeaderboardEntry>[];
      for (final item in rawList) {
        if (item is Map) {
          final parsed = LeaderboardEntry.fromCacheJson(
            Map<String, dynamic>.from(item),
          );
          if (parsed != null) restored.add(parsed);
        }
      }
      if (restored.isNotEmpty) {
        _osmEntries = restored;
        _anchorLabel = decoded['anchorLabel']?.toString();
        _anchorLat = (decoded['anchorLat'] as num?)?.toDouble();
        _anchorLon = (decoded['anchorLon'] as num?)?.toDouble();
        _radiusMeters = (decoded['radiusMeters'] as num?)?.toDouble() ?? 2000;
        _lastFetchedAt =
            DateTime.tryParse(decoded['lastFetchedAt']?.toString() ?? '');
        _hasSyncedOsm = true;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[EdgeMapper] OSM leaderboard cache restore skipped: $e');
    }
  }

  Future<void> _persistCache() async {
    final db = _db;
    if (db == null) return;
    try {
      await db.setSetting(
        _cacheSettingsKey,
        jsonEncode({
          'anchorLabel': _anchorLabel,
          'anchorLat': _anchorLat,
          'anchorLon': _anchorLon,
          'radiusMeters': _radiusMeters,
          'lastFetchedAt': _lastFetchedAt?.toUtc().toIso8601String(),
          'entries': _osmEntries.map((e) => e.toCacheJson()).toList(),
        }),
      );
    } catch (e) {
      debugPrint('[EdgeMapper] OSM leaderboard cache save skipped: $e');
    }
  }

  /// Builds a bounding box (`minLon,minLat,maxLon,maxLat`) around ([lat], [lon])
  /// with half-width [radiusMeters].
  static String buildBboxQueryParam({
    required double latitude,
    required double longitude,
    required double radiusMeters,
  }) {
    final latDelta = (radiusMeters / 111320.0).clamp(0.002, 0.25);
    final cosLat = math.cos(latitude * math.pi / 180.0).abs().clamp(0.15, 1.0);
    final lonDelta = (radiusMeters / (111320.0 * cosLat)).clamp(0.002, 0.35);
    final minLon = (longitude - lonDelta).clamp(-180.0, 180.0);
    final maxLon = (longitude + lonDelta).clamp(-180.0, 180.0);
    final minLat = (latitude - latDelta).clamp(-85.0, 85.0);
    final maxLat = (latitude + latDelta).clamp(-85.0, 85.0);
    return '${minLon.toStringAsFixed(5)},${minLat.toStringAsFixed(5)},'
        '${maxLon.toStringAsFixed(5)},${maxLat.toStringAsFixed(5)}';
  }

  /// Fetches real OpenStreetMap contributors who have mapped near the given
  /// Point of Interest ([latitude], [longitude]) within [radiusMeters]:
  /// 1. Queries `GET /api/0.6/changesets.json?bbox=...` for real local edits.
  /// 2. Batch-fetches real OSM profile stats via `GET /api/0.6/users.json?users=...`.
  /// 3. Computes XP purely from real mapped counts and caches the result offline.
  Future<void> fetchNearbyOsmMappers({
    required double latitude,
    required double longitude,
    String? poiLabel,
    double radiusMeters = 2000,
  }) async {
    _anchorLabel = (poiLabel != null && poiLabel.trim().isNotEmpty)
        ? poiLabel.trim()
        : '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
    _anchorLat = latitude;
    _anchorLon = longitude;
    _radiusMeters = radiusMeters.clamp(500, 15000);

    if (!connectivity.isOnline) {
      _lastError = 'Offline — showing cached OpenStreetMap mappers if available.';
      notifyListeners();
      return;
    }

    _isRefreshing = true;
    _lastError = null;
    notifyListeners();

    try {
      final bbox = buildBboxQueryParam(
        latitude: latitude,
        longitude: longitude,
        radiusMeters: _radiusMeters,
      );
      final changesetsUri = Uri.parse(
        '$_osmApiBase/api/0.6/changesets.json?bbox=$bbox',
      );
      final csResp = await _client
          .get(
            changesetsUri,
            headers: {
              'Accept': 'application/json',
              if (!kIsWeb) 'User-Agent': _userAgent,
            },
          )
          .timeout(const Duration(seconds: 12));

      if (csResp.statusCode != 200) {
        throw Exception(
          'OpenStreetMap changesets API returned HTTP ${csResp.statusCode}',
        );
      }

      final csBody = utf8.decode(csResp.bodyBytes, allowMalformed: true);
      final csDecoded = jsonDecode(csBody) as Map<String, dynamic>;
      final rawChangesets = csDecoded['changesets'] as List? ?? const [];

      final accumulators = <int, _OsmAreaAccumulator>{};
      final maxCenterDist = math.max(_radiusMeters * 3.0, 10000.0);

      for (final raw in rawChangesets) {
        if (raw is! Map) continue;
        final uid = (raw['uid'] as num?)?.toInt();
        final user = raw['user']?.toString().trim() ?? '';
        if (uid == null || uid <= 0 || user.isEmpty) continue;

        final minLat = (raw['min_lat'] as num?)?.toDouble();
        final maxLat = (raw['max_lat'] as num?)?.toDouble();
        final minLon = (raw['min_lon'] as num?)?.toDouble();
        final maxLon = (raw['max_lon'] as num?)?.toDouble();
        if (minLat == null ||
            maxLat == null ||
            minLon == null ||
            maxLon == null) {
          continue;
        }

        // Exclude giant regional/continental changesets so only genuine local
        // mappers around the POI appear in the Guild ranking.
        final latSpan = (maxLat - minLat).abs();
        final lonSpan = (maxLon - minLon).abs();
        if (latSpan > maxLocalChangesetSpanDeg ||
            lonSpan > maxLocalChangesetSpanDeg) {
          continue;
        }

        final centerLat = (minLat + maxLat) / 2.0;
        final centerLon = (minLon + maxLon) / 2.0;
        final containsPoi = latitude >= minLat &&
            latitude <= maxLat &&
            longitude >= minLon &&
            longitude <= maxLon;
        final dist = haversineMeters(
          latitude,
          longitude,
          centerLat,
          centerLon,
        );
        if (!containsPoi && dist > maxCenterDist) continue;

        final changesCount =
            math.max(1, (raw['changes_count'] as num?)?.toInt() ?? 1);
        final ts = DateTime.tryParse(
          raw['closed_at']?.toString() ?? raw['created_at']?.toString() ?? '',
        );

        final acc = accumulators.putIfAbsent(
          uid,
          () => _OsmAreaAccumulator(uid: uid, username: user),
        );
        acc.username = user;
        acc.areaChanges += changesCount;
        acc.areaChangesets += 1;
        if (dist < acc.nearestDistanceMeters) {
          acc.nearestDistanceMeters = dist;
        }
        if (ts != null &&
            (acc.lastMappedAt == null || ts.isAfter(acc.lastMappedAt!))) {
          acc.lastMappedAt = ts;
        }
      }

      // Take top 24 local mappers by local mapped volume to enrich via batch users.json
      final topLocal = accumulators.values.toList()
        ..sort((a, b) {
          final byChanges = b.areaChanges.compareTo(a.areaChanges);
          if (byChanges != 0) return byChanges;
          return b.areaChangesets.compareTo(a.areaChangesets);
        });
      final selected = topLocal.take(24).toList();

      // Batch fetch real lifetime OSM profile stats (`changesets.count`, `traces.count`)
      final userIdsToFetch = <int>{
        for (final a in selected) a.uid,
        if (prefs.osmUserId != null && prefs.osmUserId! > 0) prefs.osmUserId!,
      };
      final profileStatsByUid = <int, _OsmUserProfileStats>{};
      if (userIdsToFetch.isNotEmpty) {
        try {
          final usersUri = Uri.parse(
            '$_osmApiBase/api/0.6/users.json?users=${userIdsToFetch.join(',')}',
          );
          final uResp = await _client
              .get(
                usersUri,
                headers: {
                  'Accept': 'application/json',
                  if (!kIsWeb) 'User-Agent': _userAgent,
                },
              )
              .timeout(const Duration(seconds: 10));
          if (uResp.statusCode == 200) {
            final uBody = utf8.decode(uResp.bodyBytes, allowMalformed: true);
            final uDecoded = jsonDecode(uBody) as Map<String, dynamic>;
            final usersList = uDecoded['users'] as List? ?? const [];
            for (final item in usersList) {
              final u = item is Map && item['user'] is Map
                  ? item['user'] as Map
                  : (item is Map ? item : null);
              if (u == null) continue;
              final uid = (u['id'] as num?)?.toInt();
              final name = u['display_name']?.toString().trim() ?? '';
              if (uid == null || uid <= 0 || name.isEmpty) continue;
              final csMap = u['changesets'];
              final trMap = u['traces'];
              final csCount = csMap is Map
                  ? ((csMap['count'] as num?)?.toInt() ?? 0)
                  : 0;
              final trCount = trMap is Map
                  ? ((trMap['count'] as num?)?.toInt() ?? 0)
                  : 0;
              profileStatsByUid[uid] = _OsmUserProfileStats(
                uid: uid,
                displayName: name,
                lifetimeChangesets: csCount,
                tracesCount: trCount,
                accountCreatedAt:
                    DateTime.tryParse(u['account_created']?.toString() ?? ''),
              );
            }
          }
        } catch (e) {
          debugPrint('[EdgeMapper] OSM batch users.json enrichment skipped: $e');
        }
      }

      if (prefs.osmUserId != null &&
          profileStatsByUid.containsKey(prefs.osmUserId)) {
        _currentUserOsmStats = profileStatsByUid[prefs.osmUserId];
      }

      final entries = <LeaderboardEntry>[];
      for (final acc in selected) {
        final profile = profileStatsByUid[acc.uid];
        final realName = profile?.displayName ?? acc.username;
        final lifetimeCs = profile?.lifetimeChangesets ?? acc.areaChangesets;
        final traces = profile?.tracesCount ?? 0;
        final xp = computeRealOsmXp(
          areaChangesCount: acc.areaChanges,
          areaChangesetsCount: acc.areaChangesets,
          lifetimeChangesetsCount: lifetimeCs,
          tracesCount: traces,
        );
        final lv = GamificationService.levelForXp(xp);
        final seed = 'osm-${acc.uid}';
        final avatar = ExplorerAvatarService.buildAvatar(
          seed: seed,
          level: lv,
          xp: xp,
          recordsCount: acc.areaChanges,
          multiPhotoRecordsCount: acc.areaChangesets,
          multilingualRecordsCount: acc.areaChangesets,
          offlineRecordsCount: 0,
          totalTrailKm: traces * 1.5,
          activeDayStreak: math.max(1, math.min(acc.areaChangesets, 14)),
        );

        entries.add(
          LeaderboardEntry(
            explorerId: 'osm_${acc.uid}',
            displayName: realName,
            funnyNickname: avatar.funnyNickname,
            avatarSeed: seed,
            level: lv,
            xp: xp,
            recordsCount: acc.areaChanges,
            trailsKm: traces.toDouble(),
            verifiedProofsCount: acc.areaChangesets,
            isCurrentUser: false,
            isCommunitySynced: true,
            osmUserId: acc.uid,
            osmAreaChangesCount: acc.areaChanges,
            osmAreaChangesetsCount: acc.areaChangesets,
            osmLifetimeChangesets: lifetimeCs,
            osmTracesCount: traces,
            distanceToPoiMeters: acc.nearestDistanceMeters.isFinite
                ? acc.nearestDistanceMeters
                : null,
            lastMappedAt: acc.lastMappedAt,
            osmAccountCreatedAt: profile?.accountCreatedAt,
            osmProfileUrl:
                'https://www.openstreetmap.org/user/${Uri.encodeComponent(realName)}',
          ),
        );
      }

      _osmEntries = entries;
      _hasSyncedOsm = true;
      _lastFetchedAt = DateTime.now();
      await _persistCache();
    } catch (e) {
      _lastError = 'Could not load OpenStreetMap contributors: $e';
      debugPrint('[EdgeMapper] OSM leaderboard fetch failed: $e');
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// Convenience refresh used by UI buttons — fetches real OpenStreetMap mappers
  /// around ([latitude], [longitude]) when coordinates are provided.
  Future<void> syncWithFirestore({
    required ExplorerProfile currentProfile,
    required int recordsCount,
    required double totalTrailKm,
    int verifiedProofsCount = 0,
    double? latitude,
    double? longitude,
    String? poiLabel,
    double? radiusMeters,
  }) async {
    final lat = latitude ?? _anchorLat;
    final lon = longitude ?? _anchorLon;
    if (lat != null && lon != null) {
      await fetchNearbyOsmMappers(
        latitude: lat,
        longitude: lon,
        poiLabel: poiLabel ?? _anchorLabel,
        radiusMeters: radiusMeters ?? _radiusMeters,
      );
    }
  }

  /// Computes the live [LeaderboardSnapshot] ranking the current user against
  /// real OpenStreetMap contributors who mapped near the Point of Interest.
  LeaderboardSnapshot buildSnapshot({
    required ExplorerProfile currentProfile,
    required int recordsCount,
    required double totalTrailKm,
    int verifiedProofsCount = 0,
  }) {
    final signedInUid = prefs.osmUserId;
    final signedInName = prefs.osmUsername.trim();

    // Check if the signed-in user already appears among the real local OSM contributors
    LeaderboardEntry? matchedOsmSelf;
    final otherOsmEntries = <LeaderboardEntry>[];
    for (final e in _osmEntries) {
      final matchesUid = signedInUid != null &&
          signedInUid > 0 &&
          e.osmUserId == signedInUid;
      final matchesName = signedInName.isNotEmpty &&
          e.displayName.toLowerCase() == signedInName.toLowerCase();
      if (matchesUid || matchesName) {
        matchedOsmSelf = e;
      } else {
        otherOsmEntries.add(e);
      }
    }

    final int selfOsmXp;
    final int selfAreaChanges;
    final int selfAreaChangesets;
    final int selfLifetimeChangesets;
    final int selfTraces;
    final int? selfOsmUid;
    final String? selfOsmProfileUrl;
    final double? selfDistanceToPoi;
    final DateTime? selfLastMappedAt;
    final DateTime? selfOsmCreatedAt;

    if (matchedOsmSelf != null) {
      selfOsmXp = matchedOsmSelf.xp;
      selfAreaChanges = matchedOsmSelf.osmAreaChangesCount;
      selfAreaChangesets = matchedOsmSelf.osmAreaChangesetsCount;
      selfLifetimeChangesets = matchedOsmSelf.osmLifetimeChangesets;
      selfTraces = matchedOsmSelf.osmTracesCount;
      selfOsmUid = matchedOsmSelf.osmUserId;
      selfOsmProfileUrl = matchedOsmSelf.osmProfileUrl;
      selfDistanceToPoi = matchedOsmSelf.distanceToPoiMeters;
      selfLastMappedAt = matchedOsmSelf.lastMappedAt;
      selfOsmCreatedAt = matchedOsmSelf.osmAccountCreatedAt;
    } else if (_currentUserOsmStats != null) {
      selfOsmXp = computeRealOsmXp(
        areaChangesCount: 0,
        areaChangesetsCount: 0,
        lifetimeChangesetsCount: _currentUserOsmStats!.lifetimeChangesets,
        tracesCount: _currentUserOsmStats!.tracesCount,
      );
      selfAreaChanges = 0;
      selfAreaChangesets = 0;
      selfLifetimeChangesets = _currentUserOsmStats!.lifetimeChangesets;
      selfTraces = _currentUserOsmStats!.tracesCount;
      selfOsmUid = _currentUserOsmStats!.uid;
      selfOsmProfileUrl =
          'https://www.openstreetmap.org/user/${Uri.encodeComponent(_currentUserOsmStats!.displayName)}';
      selfDistanceToPoi = 0;
      selfLastMappedAt = null;
      selfOsmCreatedAt = _currentUserOsmStats!.accountCreatedAt;
    } else {
      selfOsmXp = 0;
      selfAreaChanges = 0;
      selfAreaChangesets = 0;
      selfLifetimeChangesets = 0;
      selfTraces = 0;
      selfOsmUid = signedInUid;
      selfOsmProfileUrl = signedInName.isNotEmpty
          ? 'https://www.openstreetmap.org/user/${Uri.encodeComponent(signedInName)}'
          : null;
      selfDistanceToPoi = 0;
      selfLastMappedAt = null;
      selfOsmCreatedAt = null;
    }

    final totalUserXp = selfOsmXp + currentProfile.xp;
    final totalUserLevel = GamificationService.levelForXp(totalUserXp);
    final resolvedUserName = signedInName.isNotEmpty
        ? signedInName
        : prefs.explorerHandle;

    final userEntry = LeaderboardEntry(
      explorerId: selfOsmUid != null ? 'osm_$selfOsmUid' : prefs.explorerId,
      displayName: resolvedUserName,
      funnyNickname: currentProfile.avatar.funnyNickname,
      avatarSeed: selfOsmUid != null ? 'osm-$selfOsmUid' : prefs.avatarSeed,
      level: totalUserLevel,
      xp: totalUserXp,
      recordsCount: selfAreaChanges > 0 ? selfAreaChanges + recordsCount : recordsCount,
      trailsKm: totalTrailKm,
      verifiedProofsCount: verifiedProofsCount,
      isCurrentUser: true,
      isCommunitySynced: _hasSyncedOsm,
      osmUserId: selfOsmUid,
      osmAreaChangesCount: selfAreaChanges,
      osmAreaChangesetsCount: selfAreaChangesets,
      osmLifetimeChangesets: selfLifetimeChangesets,
      osmTracesCount: selfTraces,
      distanceToPoiMeters: selfDistanceToPoi,
      lastMappedAt: selfLastMappedAt,
      osmAccountCreatedAt: selfOsmCreatedAt,
      osmProfileUrl: selfOsmProfileUrl,
    );

    final sorted = <LeaderboardEntry>[
      ...otherOsmEntries,
      userEntry,
    ]..sort((a, b) {
        final byXp = b.xp.compareTo(a.xp);
        if (byXp != 0) return byXp;
        final byChanges = b.osmAreaChangesCount.compareTo(a.osmAreaChangesCount);
        if (byChanges != 0) return byChanges;
        final byRec = b.recordsCount.compareTo(a.recordsCount);
        if (byRec != 0) return byRec;
        if (a.isCurrentUser != b.isCurrentUser) {
          return a.isCurrentUser ? -1 : 1;
        }
        return a.displayName.compareTo(b.displayName);
      });

    final ranked = <LeaderboardEntry>[];
    LeaderboardEntry resolvedUser = userEntry;
    int userRank = sorted.length;
    for (var i = 0; i < sorted.length; i++) {
      final entry = sorted[i].withRank(i + 1);
      ranked.add(entry);
      if (entry.isCurrentUser) {
        resolvedUser = entry;
        userRank = i + 1;
      }
    }

    final total = ranked.length;
    final percentileTop = ((userRank / total) * 100).ceil().clamp(1, 100);
    final rivalAbove = userRank > 1 ? ranked[userRank - 2] : null;
    final xpToNext = rivalAbove != null
        ? math.max(1, rivalAbove.xp - resolvedUser.xp + 1)
        : 0;

    final String standingLabel;
    if (total == 1) {
      standingLabel = _hasSyncedOsm
          ? '#1 Local Mapper (No other recent OSM edits here)'
          : 'Ready to Load Real OSM Ranking';
    } else if (userRank == 1) {
      standingLabel = '#1 Top Local OSM Mapper!';
    } else if (userRank <= 3) {
      standingLabel = 'Podium #$userRank of $total · Top $percentileTop%';
    } else if (userRank == total) {
      standingLabel = 'Rank #$userRank of $total near POI';
    } else {
      standingLabel = 'Rank #$userRank of $total · Top $percentileTop%';
    }

    final String incentive;
    if (total == 1 && !_hasSyncedOsm) {
      incentive =
          'Tap Refresh (or capture a POI with GPS) to rank against real OpenStreetMap contributors who mapped near your POI.';
    } else if (userRank == 1 && total > 1) {
      final lead = resolvedUser.xp - ranked[1].xp;
      incentive =
          'You lead real local OSM mappers near ${_anchorLabel ?? 'this POI'} (+$lead XP ahead of ${ranked[1].displayName})!';
    } else if (rivalAbove != null) {
      final editsNeeded = (xpToNext / 35).ceil().clamp(1, 999);
      incentive =
          'Map ~$editsNeeded more POI${editsNeeded == 1 ? '' : 's'} ($xpToNext XP) to overtake ${rivalAbove.displayName} for #${userRank - 1} near ${_anchorLabel ?? 'this POI'}!';
    } else {
      incentive =
          'Be the first active OpenStreetMap mapper around ${_anchorLabel ?? 'this POI'} — publish your captured POIs to OSM!';
    }

    return LeaderboardSnapshot(
      entries: ranked,
      currentUser: resolvedUser,
      currentUserRank: userRank,
      totalMappers: total,
      percentileTop: percentileTop,
      nextRivalAbove: rivalAbove,
      xpToNextRank: xpToNext,
      standingLabel: standingLabel,
      incentiveMessage: incentive,
      syncedWithCloud: _hasSyncedOsm,
      anchorLabel: _anchorLabel,
      anchorLatitude: _anchorLat,
      anchorLongitude: _anchorLon,
      radiusMeters: _radiusMeters,
      lastFetchedAt: _lastFetchedAt,
      lastError: _lastError,
    );
  }
}
