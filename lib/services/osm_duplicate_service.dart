import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/osm_tag_standards.dart';
import '../models/hike_trail.dart';
import '../models/osm_record.dart';
import 'app_env_config.dart';

enum DuplicateCheckOutcome {
  /// Remote OSM lookup succeeded and zero duplicates were found.
  passed,

  /// One or more existing OSM POIs/ways (or local batch items) matched.
  duplicatesFound,

  /// Remote OSM verification failed (e.g. HTTP 502, timeout, offline) — never
  /// reported as "passed".
  serverWarning,
}

class NearbyOsmElement {
  final String type; // node | way
  final int id;
  final int? version;
  final double latitude;
  final double longitude;
  final Map<String, String> tags;
  final List<int> nodeIds;
  final List<GeoPoint> geometry;

  const NearbyOsmElement({
    required this.type,
    required this.id,
    this.version,
    required this.latitude,
    required this.longitude,
    required this.tags,
    this.nodeIds = const [],
    this.geometry = const [],
  });

  String get displayName =>
      tags['name'] ??
      tags['name:en'] ??
      tags['brand'] ??
      tags['ref'] ??
      primaryCategory;

  String get primaryCategory {
    const keys = [
      'amenity',
      'shop',
      'tourism',
      'highway',
      'leisure',
      'natural',
      'historic',
      'information',
      'building',
      'man_made',
    ];
    for (final k in keys) {
      final v = tags[k];
      if (v != null && v.isNotEmpty) return '$k=$v';
    }
    return tags.isNotEmpty
        ? '${tags.entries.first.key}=${tags.entries.first.value}'
        : 'osm:$type/$id';
  }

  bool get isBuilding => (tags['building'] ?? '').isNotEmpty;

  bool get hasPolygonGeometry => type == 'way' && geometry.length >= 3;

  bool get isPoi => OsmDuplicateService.isMappablePoi(this);

  /// Useful OSM keys that are missing on this feature and could be added on
  /// the ground to improve map quality.
  List<String> get missingRecommendedKeys {
    final candidates = <String>[];
    final amenity = tags['amenity'] ?? '';
    final shop = tags['shop'] ?? '';
    final tourism = tags['tourism'] ?? '';
    final leisure = tags['leisure'] ?? '';

    if (isBuilding && !isPoi) {
      candidates.addAll(const [
        'name',
        'building:levels',
        'addr:housenumber',
        'addr:street',
        'roof:shape',
        'wheelchair',
      ]);
    } else if (amenity == 'bench') {
      candidates.addAll(const [
        'backrest',
        'material',
        'seats',
        'colour',
        'armrest',
      ]);
    } else if (amenity == 'toilets') {
      candidates.addAll(const [
        'wheelchair',
        'fee',
        'changing_table',
        'opening_hours',
        'unisex',
      ]);
    } else if (amenity == 'cafe' ||
        amenity == 'restaurant' ||
        amenity == 'fast_food' ||
        amenity == 'bar') {
      candidates.addAll(const [
        'name',
        'opening_hours',
        'cuisine',
        'wheelchair',
        'outdoor_seating',
        'payment:credit_cards',
        'website',
      ]);
    } else if (amenity.isNotEmpty ||
        shop.isNotEmpty ||
        tourism.isNotEmpty ||
        leisure.isNotEmpty) {
      candidates.addAll(const [
        'name',
        'opening_hours',
        'wheelchair',
        'addr:housenumber',
        'website',
        'phone',
      ]);
    } else {
      candidates.addAll(const [
        'name',
        'description',
        'wheelchair',
      ]);
    }

    return candidates
        .where((k) => (tags[k] ?? '').trim().isEmpty)
        .toList(growable: false);
  }
}

class TagDifference {
  final String key;
  final String existingValue;
  final String proposedValue;

  const TagDifference({
    required this.key,
    required this.existingValue,
    required this.proposedValue,
  });
}

class DuplicateMatch {
  final String existingOsmType; // node | way | local
  final int existingOsmId;
  final String existingName;
  final String existingCategory;
  final double distanceMeters;
  final double confidence; // 0..1
  final String reason;
  final NearbyOsmElement? existingElement;

  /// Useful tags on our local record whose key is NOT yet present on OSM.
  final Map<String, String> newTagsAvailable;

  /// Useful tags present on both local record & OSM, but with different values.
  final List<TagDifference> differingTagsAvailable;

  /// Tags currently present on upstream OSM that are NOT in our local record
  /// (e.g. tags removed locally or deprecated upstream tags like `day_off`).
  final Map<String, String> upstreamOnlyTags;

  const DuplicateMatch({
    required this.existingOsmType,
    required this.existingOsmId,
    required this.existingName,
    required this.existingCategory,
    required this.distanceMeters,
    required this.confidence,
    required this.reason,
    this.existingElement,
    this.newTagsAvailable = const {},
    this.differingTagsAvailable = const [],
    this.upstreamOnlyTags = const {},
  });

  String get osmRef => existingOsmType == 'local'
      ? 'Local batch item'
      : '$existingOsmType/$existingOsmId';

  bool get isRemoteOsmElement =>
      (existingOsmType == 'node' || existingOsmType == 'way') &&
      existingOsmId > 0;

  bool get hasSuggestedTagAdditions =>
      isRemoteOsmElement &&
      (newTagsAvailable.isNotEmpty ||
          differingTagsAvailable.isNotEmpty ||
          upstreamOnlyTags.isNotEmpty);

  bool get hasTagChanges =>
      newTagsAvailable.isNotEmpty ||
      differingTagsAvailable.isNotEmpty ||
      upstreamOnlyTags.isNotEmpty;

  Map<String, String> get existingTags => existingElement?.tags ?? const {};
}

class RecordDuplicateStatus {
  final OsmRecord record;
  final List<DuplicateMatch> matches;

  /// All nearby selectable OSM objects (points, buildings, etc.) within the
  /// search radius, sorted closest-first, so the mapper can pick the exact
  /// existing node or building way to merge tags with.
  final List<NearbyOsmElement> nearbyCandidates;

  const RecordDuplicateStatus({
    required this.record,
    required this.matches,
    this.nearbyCandidates = const [],
  });

  bool get isDuplicate => matches.isNotEmpty;
  DuplicateMatch? get strongestMatch => matches.isNotEmpty ? matches.first : null;
}

class TrailDuplicateStatus {
  final HikeTrail trail;
  final List<DuplicateMatch> matches;
  final double overlapFraction;

  const TrailDuplicateStatus({
    required this.trail,
    required this.matches,
    required this.overlapFraction,
  });

  bool get isDuplicate => matches.isNotEmpty;
}

class DuplicateCheckReport {
  final List<RecordDuplicateStatus> recordStatuses;
  final TrailDuplicateStatus? trailStatus;
  final bool usedRemoteOsmCheck;
  final String remoteSourceLabel;
  final String? warningMessage;

  const DuplicateCheckReport({
    required this.recordStatuses,
    this.trailStatus,
    required this.usedRemoteOsmCheck,
    this.remoteSourceLabel = '',
    this.warningMessage,
  });

  List<OsmRecord> get duplicateRecords => recordStatuses
      .where((s) => s.isDuplicate)
      .map((s) => s.record)
      .toList();

  List<OsmRecord> get nonDuplicateRecords => recordStatuses
      .where((s) => !s.isDuplicate)
      .map((s) => s.record)
      .toList();

  Set<String> get duplicateRecordIds =>
      recordStatuses.where((s) => s.isDuplicate).map((s) => s.record.id).toSet();

  bool get hasAnyDuplicates =>
      duplicateRecords.isNotEmpty || (trailStatus?.isDuplicate == true);

  /// Explicit outcome distinguishing genuine pass vs duplicates found vs server/network warning.
  DuplicateCheckOutcome get outcome {
    if (hasAnyDuplicates) return DuplicateCheckOutcome.duplicatesFound;
    if (!usedRemoteOsmCheck || warningMessage != null) {
      return DuplicateCheckOutcome.serverWarning;
    }
    return DuplicateCheckOutcome.passed;
  }

  RecordDuplicateStatus? statusForRecord(String recordId) {
    for (final s in recordStatuses) {
      if (s.record.id == recordId) return s;
    }
    return null;
  }
}

/// Checks local records and recorded tracks against existing OpenStreetMap
/// data (OSM API v0.6 `/api/0.6/map.json` primary + Overpass API mirrors fallback)
/// and intra-batch local duplicates BEFORE publishing.
///
/// When an existing OSM POI matches, computes exact tag diffs (new tags &
/// differing values) so the user can inspect what is already on OSM and
/// selectively add a subset of new tags instead of creating a duplicate.
class OsmDuplicateService {
  static const String _defaultOsmApiBase = 'https://api.openstreetmap.org';
  static const List<String> _overpassEndpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  /// Internal/noisy tags that should not by themselves be suggested as
  /// "new OSM feature data" when merging into an existing POI.
  static const Set<String> _ignoredSuggestionKeys = {
    'source',
    'fixme',
    'camera:direction',
    'created_by',
  };

  final http.Client _client;

  OsmDuplicateService({http.Client? client})
      : _client = client ?? http.Client();

  /// Runs a pre-upload duplicate scan for [records] and optional [trail].
  Future<DuplicateCheckReport> checkDuplicates({
    required List<OsmRecord> records,
    HikeTrail? trail,
    bool isOnline = true,
    double poiSearchRadiusMeters = 45.0,
    String osmApiBaseUrl = _defaultOsmApiBase,
    List<NearbyOsmElement>? mockNearbyElements,
  }) async {
    final nearbyElements = <NearbyOsmElement>[];
    bool usedRemote = false;
    String remoteSource = '';
    String? warning;

    if (mockNearbyElements != null) {
      nearbyElements.addAll(mockNearbyElements);
      usedRemote = true;
      remoteSource = 'OSM API v0.6';
    } else if (isOnline && (records.isNotEmpty || trail != null)) {
      final fetched = await _fetchNearbyWithFallbacks(
        records: records,
        trail: trail,
        radiusMeters: poiSearchRadiusMeters,
        osmApiBaseUrl: osmApiBaseUrl,
      );
      if (fetched.succeeded) {
        nearbyElements.addAll(fetched.elements);
        usedRemote = true;
        remoteSource = fetched.sourceLabel;
      } else {
        warning = fetched.errorMessage ??
            'Could not reach OpenStreetMap servers to verify duplicates.';
      }
    } else if (!isOnline) {
      warning =
          'Offline: could not check OpenStreetMap for existing POIs (local batch check only).';
    }

    final recordStatuses = <RecordDuplicateStatus>[];

    // Track already-seen records in this batch to catch local self-duplicates
    final seenInBatch = <OsmRecord>[];

    for (final rec in records) {
      final matches = <DuplicateMatch>[];

      final candidatesWithDist = <({NearbyOsmElement elem, double dist})>[];

      // 1. Check against remote OSM elements & collect selectable nearby points/buildings
      for (final elem in nearbyElements) {
        final match = evaluatePoiMatch(
          rec,
          elem,
          maxRadiusMeters: poiSearchRadiusMeters,
        );
        if (match != null) {
          matches.add(match);
        }
        if (isSelectableMapFeature(elem)) {
          final dist = haversineMeters(
            rec.effectiveLatitude,
            rec.effectiveLongitude,
            elem.latitude,
            elem.longitude,
          );
          if (dist <= poiSearchRadiusMeters) {
            candidatesWithDist.add((elem: elem, dist: dist));
          }
        }
      }
      candidatesWithDist.sort((a, b) => a.dist.compareTo(b.dist));
      final nearbyCandidates =
          candidatesWithDist.take(25).map((e) => e.elem).toList();

      // 2. Check against earlier records in the same upload batch
      for (final other in seenInBatch) {
        final dist = haversineMeters(
          rec.effectiveLatitude,
          rec.effectiveLongitude,
          other.effectiveLatitude,
          other.effectiveLongitude,
        );
        if (dist <= 20.0) {
          final sim = nameSimilarity(rec.displayName, other.displayName);
          final sameCat = _primaryCategoryKeyValue(rec.tags) != null &&
              _primaryCategoryKeyValue(rec.tags) ==
                  _primaryCategoryKeyValue(other.tags);
          if (sim >= 0.72 || (sameCat && dist <= 12.0)) {
            matches.add(
              DuplicateMatch(
                existingOsmType: 'local',
                existingOsmId: 0,
                existingName: other.displayName,
                existingCategory: other.primaryCategoryTag,
                distanceMeters: dist,
                confidence: math.max(sim, sameCat ? 0.85 : 0.75),
                reason:
                    'Duplicate of another selected draft "${other.displayName}" (${dist.round()}m apart).',
              ),
            );
          }
        }
      }

      matches.sort((a, b) => b.confidence.compareTo(a.confidence));
      recordStatuses.add(
        RecordDuplicateStatus(
          record: rec,
          matches: matches,
          nearbyCandidates: nearbyCandidates,
        ),
      );
      if (matches.isEmpty) {
        seenInBatch.add(rec);
      }
    }

    TrailDuplicateStatus? trailStatus;
    if (trail != null && trail.points.length >= 2) {
      trailStatus = evaluateTrailDuplicates(trail, nearbyElements);
    }

    return DuplicateCheckReport(
      recordStatuses: recordStatuses,
      trailStatus: trailStatus,
      usedRemoteOsmCheck: usedRemote,
      remoteSourceLabel: remoteSource,
      warningMessage: warning,
    );
  }

  /// Computes tags from [record] that are new, modified, or only present upstream
  /// compared to [existingTags] on OSM (allowing adding, updating, or removing tags upstream).
  static ({
    Map<String, String> newTags,
    List<TagDifference> differingTags,
    Map<String, String> upstreamOnlyTags,
  }) computeSuggestedTagAdditions({
    required OsmRecord record,
    required Map<String, String> existingTags,
  }) {
    final newTags = <String, String>{};
    final differing = <TagDifference>[];
    final upstreamOnly = <String, String>{};

    final hasGps = OsmTagStandards.hasValidGps(
      record.effectiveLatitude,
      record.effectiveLongitude,
    );
    // Modernize legacy/deprecated tags (e.g. day_off -> opening_hours) and strip
    // local-only metadata (e.g. camera:direction on non-camera POIs) BEFORE diffing!
    final candidateTags = OsmTagStandards.modernizeTags(
      record.tags,
      hasGpsFix: hasGps,
      stripLocalOnly: true,
    );

    for (final entry in candidateTags.entries) {
      final key = entry.key.trim();
      final val = entry.value.trim();
      if (key.isEmpty || val.isEmpty) continue;
      if (OsmTagStandards.isLocalOnlyTag(key, candidateTags)) continue;

      final isIgnored = _ignoredSuggestionKeys.contains(key);
      if (!existingTags.containsKey(key)) {
        if (!isIgnored) {
          newTags[key] = val;
        }
      } else {
        final existingVal = existingTags[key]!.trim();
        // Allow updating a legacy software-name or invalid GPS `source` on OSM to `survey`
        final allowSourceUpgrade = key == 'source' &&
            OsmTagStandards.isLegacyOrInvalidSource(existingVal) &&
            !OsmTagStandards.isLegacyOrInvalidSource(val);
        if ((!isIgnored || allowSourceUpgrade) && existingVal != val) {
          differing.add(
            TagDifference(
              key: key,
              existingValue: existingVal,
              proposedValue: val,
            ),
          );
        }
      }
    }

    // Identify tags currently on upstream OSM that are NOT in our local record
    // (e.g., deprecated tags like `day_off` or tags the mapper deleted locally).
    for (final entry in existingTags.entries) {
      final key = entry.key.trim();
      final val = entry.value.trim();
      if (key.isEmpty || val.isEmpty) continue;
      if (!candidateTags.containsKey(key)) {
        upstreamOnly[key] = val;
      }
    }

    return (
      newTags: newTags,
      differingTags: differing,
      upstreamOnlyTags: upstreamOnly,
    );
  }

  /// Builds a [DuplicateMatch] tag-merge comparison between [record] and any
  /// user-selected existing OSM [element] (building, point, way, etc.).
  static DuplicateMatch buildMatchForElement(
    OsmRecord record,
    NearbyOsmElement element,
  ) {
    final dist = haversineMeters(
      record.effectiveLatitude,
      record.effectiveLongitude,
      element.latitude,
      element.longitude,
    );
    final suggestions = computeSuggestedTagAdditions(
      record: record,
      existingTags: element.tags,
    );
    final kindLabel = element.isBuilding && !element.isPoi
        ? 'building'
        : (element.type == 'way' ? 'area/way' : 'point');
    return DuplicateMatch(
      existingOsmType: element.type,
      existingOsmId: element.id,
      existingName: element.displayName,
      existingCategory: element.primaryCategory,
      distanceMeters: dist,
      confidence: 1.0,
      reason:
          'Selected OSM $kindLabel "${element.displayName}" (${dist.round()}m away) for tag merge.',
      existingElement: element,
      newTagsAvailable: suggestions.newTags,
      differingTagsAvailable: suggestions.differingTags,
      upstreamOnlyTags: suggestions.upstreamOnlyTags,
    );
  }

  /// Evaluates whether [record] duplicates an existing [element] on OpenStreetMap.
  static DuplicateMatch? evaluatePoiMatch(
    OsmRecord record,
    NearbyOsmElement element, {
    double maxRadiusMeters = 45.0,
  }) {
    final dist = haversineMeters(
      record.effectiveLatitude,
      record.effectiveLongitude,
      element.latitude,
      element.longitude,
    );
    if (dist > maxRadiusMeters) return null;

    final recNames = _extractAllNames(record.tags, fallback: record.displayName);
    final elemNames = _extractAllNames(element.tags);
    double bestNameSim = 0.0;
    for (final rn in recNames) {
      for (final en in elemNames) {
        final s = nameSimilarity(rn, en);
        if (s > bestNameSim) bestNameSim = s;
      }
    }

    final recCat = _primaryCategoryKeyValue(record.tags);
    final elemCat = _primaryCategoryKeyValue(element.tags);
    final exactCatMatch = recCat != null && recCat == elemCat;
    final sameDomainKey = recCat != null &&
        elemCat != null &&
        recCat.split('=').first == elemCat.split('=').first;

    double score = 0.0;
    String? reason;

    if (bestNameSim >= 0.72) {
      score = 0.72 + bestNameSim * 0.23 + (exactCatMatch ? 0.05 : 0.0);
      reason =
          'Already registered as "${element.displayName}" (${(bestNameSim * 100).round()}% name match) ${dist.round()}m away on OSM.';
    } else if (exactCatMatch && dist <= 18.0) {
      score = 0.88 - (dist / 100.0);
      reason =
          'Existing $elemCat already registered ${dist.round()}m away on OSM.';
    } else if (sameDomainKey && bestNameSim >= 0.50 && dist <= 35.0) {
      score = 0.70 + bestNameSim * 0.2;
      reason =
          'Similar nearby ${element.primaryCategory} "${element.displayName}" ${dist.round()}m away on OSM.';
    }

    if (reason == null) return null;

    final suggestions = computeSuggestedTagAdditions(
      record: record,
      existingTags: element.tags,
    );

    return DuplicateMatch(
      existingOsmType: element.type,
      existingOsmId: element.id,
      existingName: element.displayName,
      existingCategory: element.primaryCategory,
      distanceMeters: dist,
      confidence: score.clamp(0.5, 0.99),
      reason: reason,
      existingElement: element,
      newTagsAvailable: suggestions.newTags,
      differingTagsAvailable: suggestions.differingTags,
      upstreamOnlyTags: suggestions.upstreamOnlyTags,
    );
  }

  /// Checks whether a recorded [trail] substantially overlaps an existing OSM highway way.
  static TrailDuplicateStatus evaluateTrailDuplicates(
    HikeTrail trail,
    List<NearbyOsmElement> nearbyElements,
  ) {
    final highwayWays = nearbyElements
        .where(
          (e) =>
              e.type == 'way' &&
              e.tags.containsKey('highway') &&
              e.geometry.length >= 2,
        )
        .toList();

    if (highwayWays.isEmpty || trail.points.length < 2) {
      return TrailDuplicateStatus(
        trail: trail,
        matches: const [],
        overlapFraction: 0.0,
      );
    }

    final step = math.max(1, (trail.points.length / 30).ceil());
    final sampled = <TrailPoint>[];
    for (var i = 0; i < trail.points.length; i += step) {
      sampled.add(trail.points[i]);
    }
    if (sampled.last != trail.points.last) {
      sampled.add(trail.points.last);
    }

    int overlappingCount = 0;
    final wayHits = <int, int>{};
    final wayById = <int, NearbyOsmElement>{};

    for (final pt in sampled) {
      NearbyOsmElement? closestWay;
      double bestDist = double.infinity;
      for (final way in highwayWays) {
        wayById[way.id] = way;
        for (final g in way.geometry) {
          final d = haversineMeters(
            pt.latitude,
            pt.longitude,
            g.latitude,
            g.longitude,
          );
          if (d < bestDist) {
            bestDist = d;
            closestWay = way;
          }
        }
      }
      if (closestWay != null && bestDist <= 18.0) {
        overlappingCount++;
        wayHits[closestWay.id] = (wayHits[closestWay.id] ?? 0) + 1;
      }
    }

    final overlap = overlappingCount / sampled.length;
    final matches = <DuplicateMatch>[];

    if (overlap >= 0.65) {
      final sortedWayIds = wayHits.keys.toList()
        ..sort((a, b) => (wayHits[b] ?? 0).compareTo(wayHits[a] ?? 0));
      for (final wid in sortedWayIds.take(3)) {
        final way = wayById[wid]!;
        final pct = ((wayHits[wid]! / sampled.length) * 100).round();
        matches.add(
          DuplicateMatch(
            existingOsmType: 'way',
            existingOsmId: way.id,
            existingName: way.displayName,
            existingCategory: way.primaryCategory,
            distanceMeters: 0,
            confidence: overlap.clamp(0.65, 0.99),
            reason:
                '${(overlap * 100).round()}% of this route overlaps existing OSM ${way.primaryCategory} "${way.displayName}" ($pct% direct match). Consider uploading as a GPX Trace instead of creating a duplicate way.',
            existingElement: way,
          ),
        );
      }
    }

    return TrailDuplicateStatus(
      trail: trail,
      matches: matches,
      overlapFraction: overlap,
    );
  }

  /// Tries direct OSM API v0.6 `/api/0.6/map.json` FIRST (live, authoritative,
  /// includes exact element versions & tags, and immune to Overpass 502 spikes),
  /// then falls back to Overpass API mirrors if needed.
  Future<
      ({
        bool succeeded,
        List<NearbyOsmElement> elements,
        String sourceLabel,
        String? errorMessage,
      })> _fetchNearbyWithFallbacks({
    required List<OsmRecord> records,
    HikeTrail? trail,
    required double radiusMeters,
    required String osmApiBaseUrl,
  }) async {
    final errors = <String>[];

    // 1. Primary: Direct OSM API v0.6 /api/0.6/map.json for small POI bboxes (and small trails)
    final canUseOsmMapApi =
        (trail == null || _trailSpanDegrees(trail) <= 0.015) &&
            records.length <= 8;
    if (canUseOsmMapApi) {
      try {
        final directElements = await _fetchViaOsmMapApi(
          records: records,
          trail: trail,
          radiusMeters: radiusMeters,
          osmApiBaseUrl: osmApiBaseUrl,
        );
        return (
          succeeded: true,
          elements: directElements,
          sourceLabel: 'OSM API v0.6',
          errorMessage: null,
        );
      } catch (e) {
        errors.add('OSM API v0.6: ${_cleanErr(e)}');
      }
    }

    // 2. Fallback: Overpass API mirrors (primary + kumi.systems)
    for (final endpoint in _overpassEndpoints) {
      try {
        final elems = await _fetchViaOverpassEndpoint(
          endpoint: endpoint,
          records: records,
          trail: trail,
          radiusMeters: radiusMeters,
        );
        return (
          succeeded: true,
          elements: elems,
          sourceLabel: 'Overpass API',
          errorMessage: null,
        );
      } catch (e) {
        errors.add('${Uri.parse(endpoint).host}: ${_cleanErr(e)}');
      }
    }

    return (
      succeeded: false,
      elements: const <NearbyOsmElement>[],
      sourceLabel: '',
      errorMessage:
          'Could not verify against OpenStreetMap (${errors.join(' · ')}).',
    );
  }

  static double _trailSpanDegrees(HikeTrail trail) {
    if (trail.points.isEmpty) return 0;
    double minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
    for (final p in trail.points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return math.max(maxLat - minLat, maxLon - minLon);
  }

  Future<List<NearbyOsmElement>> _fetchViaOsmMapApi({
    required List<OsmRecord> records,
    HikeTrail? trail,
    required double radiusMeters,
    required String osmApiBaseUrl,
  }) async {
    final byKey = <String, NearbyOsmElement>{};
    final bboxes = <({double minLon, double minLat, double maxLon, double maxLat})>[];

    for (final r in records) {
      if (r.effectiveLatitude.abs() < 0.001 &&
          r.effectiveLongitude.abs() < 0.001) {
        continue;
      }
      final lat = r.effectiveLatitude;
      final lon = r.effectiveLongitude;
      final padLat = (radiusMeters + 15.0) / 111320.0;
      final cosLat = math.max(math.cos(lat * math.pi / 180.0).abs(), 0.2);
      final padLon = (radiusMeters + 15.0) / (111320.0 * cosLat);
      bboxes.add((
        minLon: lon - padLon,
        minLat: lat - padLat,
        maxLon: lon + padLon,
        maxLat: lat + padLat,
      ));
    }

    if (trail != null && trail.points.length >= 2) {
      double minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
      for (final p in trail.points) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLon) minLon = p.longitude;
        if (p.longitude > maxLon) maxLon = p.longitude;
      }
      const pad = 0.0003;
      bboxes.add((
        minLon: minLon - pad,
        minLat: minLat - pad,
        maxLon: maxLon + pad,
        maxLat: maxLat + pad,
      ));
    }

    if (bboxes.isEmpty) return const [];

    final base = osmApiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    for (final b in bboxes) {
      final bboxParam =
          '${b.minLon.toStringAsFixed(6)},${b.minLat.toStringAsFixed(6)},'
          '${b.maxLon.toStringAsFixed(6)},${b.maxLat.toStringAsFixed(6)}';
      final uri = Uri.parse('$base/api/0.6/map.json?bbox=$bboxParam');
      final resp = await _client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              if (!kIsWeb)
                'User-Agent':
                    AppEnvConfig.httpUserAgent(component: 'DuplicateCheck'),
            },
          )
          .timeout(const Duration(seconds: 12));

      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
      for (final elem in parseOsmApiMapJson(bodyText)) {
        byKey['${elem.type}/${elem.id}'] = elem;
      }
    }

    return byKey.values.toList();
  }

  /// Parses OpenStreetMap API v0.6 `/api/0.6/map.json` into [NearbyOsmElement]s,
  /// preserving exact `version`, `nodes`, `tags`, and computed way geometry/centroids.
  static List<NearbyOsmElement> parseOsmApiMapJson(String rawBody) {
    final decoded = jsonDecode(rawBody) as Map<String, dynamic>;
    final rawElements = decoded['elements'] as List? ?? const [];

    // First pass: index all node coordinates so ways can compute geometry & centroid
    final nodeCoords = <int, GeoPoint>{};
    for (final item in rawElements) {
      if (item is! Map) continue;
      if (item['type'] == 'node') {
        final id = (item['id'] as num?)?.toInt();
        final lat = (item['lat'] as num?)?.toDouble();
        final lon = (item['lon'] as num?)?.toDouble();
        if (id != null && lat != null && lon != null) {
          nodeCoords[id] = GeoPoint(lat, lon);
        }
      }
    }

    final results = <NearbyOsmElement>[];
    for (final item in rawElements) {
      if (item is! Map) continue;
      final type = item['type']?.toString() ?? '';
      if (type != 'node' && type != 'way') continue;
      final id = (item['id'] as num?)?.toInt() ?? 0;
      final version = (item['version'] as num?)?.toInt();
      final rawTags = item['tags'];
      if (rawTags is! Map || rawTags.isEmpty) continue;

      final tags = <String, String>{};
      rawTags.forEach((k, v) {
        final ks = k.toString().trim();
        final vs = v?.toString().trim() ?? '';
        if (ks.isNotEmpty && vs.isNotEmpty) tags[ks] = vs;
      });
      if (tags.isEmpty) continue;

      if (type == 'node') {
        final lat = (item['lat'] as num?)?.toDouble();
        final lon = (item['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        results.add(
          NearbyOsmElement(
            type: 'node',
            id: id,
            version: version,
            latitude: lat,
            longitude: lon,
            tags: tags,
          ),
        );
      } else {
        final rawNodes = item['nodes'] as List? ?? const [];
        final nodeIds = <int>[];
        final geom = <GeoPoint>[];
        double latSum = 0;
        double lonSum = 0;
        for (final nidRaw in rawNodes) {
          final nid = (nidRaw as num?)?.toInt();
          if (nid == null) continue;
          nodeIds.add(nid);
          final pt = nodeCoords[nid];
          if (pt != null) {
            geom.add(pt);
            latSum += pt.latitude;
            lonSum += pt.longitude;
          }
        }
        if (geom.isEmpty) continue;
        results.add(
          NearbyOsmElement(
            type: 'way',
            id: id,
            version: version,
            latitude: latSum / geom.length,
            longitude: lonSum / geom.length,
            tags: tags,
            nodeIds: nodeIds,
            geometry: geom,
          ),
        );
      }
    }

    return results;
  }

  Future<List<NearbyOsmElement>> _fetchViaOverpassEndpoint({
    required String endpoint,
    required List<OsmRecord> records,
    HikeTrail? trail,
    required double radiusMeters,
  }) async {
    final clauses = <String>[];

    for (final r in records.take(25)) {
      if (r.effectiveLatitude.abs() < 0.001 &&
          r.effectiveLongitude.abs() < 0.001) {
        continue;
      }
      final lat = r.effectiveLatitude.toStringAsFixed(6);
      final lon = r.effectiveLongitude.toStringAsFixed(6);
      final rad = radiusMeters.round().clamp(15, 100);
      clauses.add('nwr(around:$rad,$lat,$lon)["name"];');
      clauses.add('nwr(around:$rad,$lat,$lon)["amenity"];');
      clauses.add('nwr(around:$rad,$lat,$lon)["shop"];');
      clauses.add('nwr(around:$rad,$lat,$lon)["tourism"];');
      clauses.add('nwr(around:$rad,$lat,$lon)["leisure"];');
      clauses.add('nwr(around:$rad,$lat,$lon)["historic"];');
      clauses.add('way(around:$rad,$lat,$lon)["building"];');
    }

    if (trail != null && trail.points.length >= 2) {
      double minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
      for (final p in trail.points) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLon) minLon = p.longitude;
        if (p.longitude > maxLon) maxLon = p.longitude;
      }
      const pad = 0.0004;
      clauses.add(
        'way["highway"](${(minLat - pad).toStringAsFixed(6)},${(minLon - pad).toStringAsFixed(6)},${(maxLat + pad).toStringAsFixed(6)},${(maxLon + pad).toStringAsFixed(6)});',
      );
    }

    if (clauses.isEmpty) return const [];

    final query =
        '[out:json][timeout:12];(${clauses.join('\n')});out meta center geom;';
    final resp = await _client
        .post(
          Uri.parse(endpoint),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            if (!kIsWeb)
              'User-Agent':
                  AppEnvConfig.httpUserAgent(component: 'Overpass'),
          },
          body: {'data': query},
        )
        .timeout(const Duration(seconds: 14));

    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}');
    }

    final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
    return parseOverpassJson(bodyText);
  }

  /// Parses Overpass JSON (`out center geom` / `out meta center geom`) into [NearbyOsmElement]s.
  static List<NearbyOsmElement> parseOverpassJson(String rawBody) {
    final decoded = jsonDecode(rawBody) as Map<String, dynamic>;
    final rawElements = decoded['elements'] as List? ?? const [];
    final results = <NearbyOsmElement>[];

    for (final item in rawElements) {
      if (item is! Map) continue;
      final type = item['type']?.toString() ?? 'node';
      final id = (item['id'] as num?)?.toInt() ?? 0;
      final version = (item['version'] as num?)?.toInt();
      final rawTags = item['tags'];
      if (rawTags is! Map || rawTags.isEmpty) continue;

      final tags = <String, String>{};
      rawTags.forEach((k, v) {
        final ks = k.toString().trim();
        final vs = v?.toString().trim() ?? '';
        if (ks.isNotEmpty && vs.isNotEmpty) tags[ks] = vs;
      });

      double? lat = (item['lat'] as num?)?.toDouble();
      double? lon = (item['lon'] as num?)?.toDouble();
      final center = item['center'];
      if ((lat == null || lon == null) && center is Map) {
        lat = (center['lat'] as num?)?.toDouble();
        lon = (center['lon'] as num?)?.toDouble();
      }

      final nodeIds = <int>[];
      final rawNodes = item['nodes'];
      if (rawNodes is List) {
        for (final n in rawNodes) {
          final nid = (n as num?)?.toInt();
          if (nid != null) nodeIds.add(nid);
        }
      }

      final geom = <GeoPoint>[];
      final rawGeom = item['geometry'];
      if (rawGeom is List) {
        for (final gp in rawGeom) {
          if (gp is Map) {
            final glat = (gp['lat'] as num?)?.toDouble();
            final glon = (gp['lon'] as num?)?.toDouble();
            if (glat != null && glon != null) {
              geom.add(GeoPoint(glat, glon));
            }
          }
        }
      }
      if ((lat == null || lon == null) && geom.isNotEmpty) {
        lat = geom.first.latitude;
        lon = geom.first.longitude;
      }
      if (lat == null || lon == null) continue;

      results.add(
        NearbyOsmElement(
          type: type,
          id: id,
          version: version,
          latitude: lat,
          longitude: lon,
          tags: tags,
          nodeIds: nodeIds,
          geometry: geom,
        ),
      );
    }

    return results;
  }

  static String _cleanErr(Object e) =>
      e.toString().replaceFirst('Exception: ', '').trim();

  static List<String> _extractAllNames(
    Map<String, String> tags, {
    String? fallback,
  }) {
    final names = <String>{};
    for (final e in tags.entries) {
      if (e.key == 'name' ||
          e.key.startsWith('name:') ||
          e.key == 'brand' ||
          e.key == 'alt_name' ||
          e.key == 'official_name') {
        final cleaned = e.value.trim();
        if (cleaned.isNotEmpty) names.add(cleaned);
      }
    }
    if (names.isEmpty &&
        fallback != null &&
        fallback.trim().isNotEmpty &&
        fallback != 'Unnamed OSM Feature') {
      names.add(fallback.trim());
    }
    return names.toList();
  }

  static String? _primaryCategoryKeyValue(Map<String, String> tags) {
    const keys = [
      'amenity',
      'shop',
      'tourism',
      'leisure',
      'historic',
      'information',
      'natural',
      'highway',
      'man_made',
    ];
    for (final k in keys) {
      final v = tags[k]?.trim().toLowerCase();
      if (v != null && v.isNotEmpty) return '$k=$v';
    }
    return null;
  }

  /// Returns true when [el] represents a meaningful mapped POI / field feature
  /// (shops, cafes, benches, parks, viewpoints, monuments, bus stops, etc.)
  /// rather than a bare road segment, boundary, or unnamed building footprint.
  static bool isMappablePoi(NearbyOsmElement el) {
    final t = el.tags;
    if (t.isEmpty) return false;

    const primaryPoiKeys = {
      'amenity',
      'shop',
      'tourism',
      'leisure',
      'historic',
      'healthcare',
      'office',
      'craft',
      'information',
      'emergency',
      'man_made',
      'sport',
      'club',
      'government',
      'diplomatic',
      'attraction',
    };
    for (final k in primaryPoiKeys) {
      if ((t[k] ?? '').isNotEmpty) return true;
    }

    const mappedHighways = {
      'bus_stop',
      'trailhead',
      'rest_area',
      'services',
      'milestone',
      'elevator',
    };
    if (mappedHighways.contains(t['highway'])) return true;

    const mappedRailways = {
      'station',
      'halt',
      'tram_stop',
      'subway_entrance',
    };
    if (mappedRailways.contains(t['railway'])) return true;

    const mappedNatural = {
      'peak',
      'volcano',
      'saddle',
      'spring',
      'waterfall',
      'cave_entrance',
      'hot_spring',
      'rock',
      'arch',
    };
    if (mappedNatural.contains(t['natural'])) return true;

    final hasName = (t['name'] ?? t['name:en'] ?? t['brand'] ?? '').isNotEmpty;
    if (hasName &&
        !t.containsKey('highway') &&
        !t.containsKey('boundary') &&
        !t.containsKey('landuse') &&
        !t.containsKey('waterway') &&
        !t.containsKey('power') &&
        !t.containsKey('route')) {
      return true;
    }

    return false;
  }

  /// Returns true when [el] should be shown and selectable on the surrounding
  /// coverage map: either a meaningful POI or a mapped building footprint.
  static bool isSelectableMapFeature(NearbyOsmElement el) =>
      isMappablePoi(el) || el.isBuilding;

  /// Fetches already-mapped OpenStreetMap POIs and buildings surrounding
  /// ([lat], [lon]) so field mappers can inspect existing tags and add better ones.
  /// Queries OSM API v0.6 `/api/0.6/map.json` first and falls back to Overpass.
  Future<
      ({
        bool succeeded,
        List<NearbyOsmElement> elements,
        String sourceLabel,
        String? errorMessage,
      })> fetchSurroundingPois({
    required double lat,
    required double lon,
    double radiusMeters = 160.0,
    String osmApiBaseUrl = _defaultOsmApiBase,
  }) async {
    if (lat.abs() < 0.0001 && lon.abs() < 0.0001) {
      return (
        succeeded: false,
        elements: const <NearbyOsmElement>[],
        sourceLabel: '',
        errorMessage: 'Waiting for GPS location.',
      );
    }

    final clampedRadius = radiusMeters.clamp(50.0, 260.0);
    final errors = <String>[];

    List<NearbyOsmElement> filterAndSort(List<NearbyOsmElement> raw) {
      final filtered = raw.where(isSelectableMapFeature).toList()
        ..sort((a, b) {
          final da = haversineMeters(lat, lon, a.latitude, a.longitude);
          final db = haversineMeters(lat, lon, b.latitude, b.longitude);
          return da.compareTo(db);
        });
      return filtered.take(260).toList();
    }

    // 1. Primary: OSM API v0.6 /api/0.6/map.json (fast, exact live data)
    try {
      final padLat = clampedRadius / 111320.0;
      final cosLat = math.max(math.cos(lat * math.pi / 180.0).abs(), 0.2);
      final padLon = clampedRadius / (111320.0 * cosLat);
      final bboxParam =
          '${(lon - padLon).toStringAsFixed(6)},${(lat - padLat).toStringAsFixed(6)},'
          '${(lon + padLon).toStringAsFixed(6)},${(lat + padLat).toStringAsFixed(6)}';
      final base = osmApiBaseUrl.replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$base/api/0.6/map.json?bbox=$bboxParam');
      final resp = await _client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              if (!kIsWeb)
                'User-Agent':
                    AppEnvConfig.httpUserAgent(component: 'CoverageMap'),
            },
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final parsed = filterAndSort(parseOsmApiMapJson(bodyText));
      return (
        succeeded: true,
        elements: parsed,
        sourceLabel: 'OSM API v0.6',
        errorMessage: null,
      );
    } catch (e) {
      errors.add('OSM API: ${_cleanErr(e)}');
    }

    // 2. Fallback: Overpass API mirrors (POIs + building footprints with geometry)
    final latStr = lat.toStringAsFixed(6);
    final lonStr = lon.toStringAsFixed(6);
    final radInt = clampedRadius.round();
    final query = '[out:json][timeout:10];('
        'nwr(around:$radInt,$latStr,$lonStr)["amenity"];'
        'nwr(around:$radInt,$latStr,$lonStr)["shop"];'
        'nwr(around:$radInt,$latStr,$lonStr)["tourism"];'
        'nwr(around:$radInt,$latStr,$lonStr)["leisure"];'
        'nwr(around:$radInt,$latStr,$lonStr)["historic"];'
        'nwr(around:$radInt,$latStr,$lonStr)["healthcare"];'
        'nwr(around:$radInt,$latStr,$lonStr)["information"];'
        'way(around:$radInt,$latStr,$lonStr)["building"];'
        ');out center geom;';
    for (final endpoint in _overpassEndpoints) {
      try {
        final resp = await _client
            .post(
              Uri.parse(endpoint),
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                if (!kIsWeb)
                  'User-Agent':
                      AppEnvConfig.httpUserAgent(component: 'CoverageMap'),
              },
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 12));
        if (resp.statusCode != 200) {
          throw Exception('HTTP ${resp.statusCode}');
        }
        final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
        final parsed = filterAndSort(parseOverpassJson(bodyText));
        return (
          succeeded: true,
          elements: parsed,
          sourceLabel: 'Overpass API',
          errorMessage: null,
        );
      } catch (e) {
        errors.add('${Uri.parse(endpoint).host}: ${_cleanErr(e)}');
      }
    }

    return (
      succeeded: false,
      elements: const <NearbyOsmElement>[],
      sourceLabel: '',
      errorMessage: 'Could not load nearby OSM places (${errors.join(' · ')})',
    );
  }

  /// Normalized similarity between two place names (0.0 .. 1.0) using
  /// case-insensitive punctuation stripping + Levenshtein ratio + token overlap.
  static double nameSimilarity(String a, String b) {
    final na = _normalizeName(a);
    final nb = _normalizeName(b);
    if (na.isEmpty || nb.isEmpty) return 0.0;
    if (na == nb) return 1.0;
    if (na.contains(nb) || nb.contains(na)) {
      final minLen = math.min(na.length, nb.length);
      final maxLen = math.max(na.length, nb.length);
      if (minLen >= 3) {
        return (0.75 + 0.25 * (minLen / maxLen)).clamp(0.0, 1.0);
      }
    }

    final dist = _levenshtein(na, nb);
    final maxLen = math.max(na.length, nb.length);
    final levSim = 1.0 - (dist / maxLen);

    final tokA = na.split(' ').where((t) => t.length >= 2).toSet();
    final tokB = nb.split(' ').where((t) => t.length >= 2).toSet();
    double jaccard = 0.0;
    if (tokA.isNotEmpty && tokB.isNotEmpty) {
      final inter = tokA.intersection(tokB).length;
      final union = tokA.union(tokB).length;
      jaccard = union > 0 ? inter / union : 0.0;
    }

    return math.max(levSim, jaccard).clamp(0.0, 1.0);
  }

  static String _normalizeName(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static int _levenshtein(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;
    final m = s.length;
    final n = t.length;
    var prev = List<int>.generate(n + 1, (j) => j);
    var curr = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      curr[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = s.codeUnitAt(i - 1) == t.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = math.min(
          math.min(curr[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + cost,
        );
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[n];
  }
}
