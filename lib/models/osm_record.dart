import 'dart:convert';
import 'dart:math' as math;

enum AiSource {
  firebaseCloud,
  personalGeminiApi,
  customAi,
  geminiNano,
  mlKitOffline,
  manual;

  String get label => switch (this) {
        AiSource.firebaseCloud => 'Firebase AI',
        AiSource.personalGeminiApi => 'Gemini API',
        AiSource.customAi => 'Custom AI',
        AiSource.geminiNano => 'Gemini Nano 4',
        AiSource.mlKitOffline => 'On-Device ML Kit',
        AiSource.manual => 'Manual',
      };

  String get shortLabel => switch (this) {
        AiSource.firebaseCloud => 'Firebase AI',
        AiSource.personalGeminiApi => 'Gemini API',
        AiSource.customAi => 'Custom AI',
        AiSource.geminiNano => 'Nano 4',
        AiSource.mlKitOffline => 'Local AI',
        AiSource.manual => 'Manual',
      };

  bool get isCloudAi =>
      this == AiSource.firebaseCloud ||
      this == AiSource.personalGeminiApi ||
      this == AiSource.customAi;

  static AiSource fromString(String? value) {
    return AiSource.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AiSource.manual,
    );
  }
}

enum RecordStatus {
  draftOffline,
  aiEnriched,
  readyToUpload,
  uploaded;

  String get label => switch (this) {
        RecordStatus.draftOffline => 'Offline Draft',
        RecordStatus.aiEnriched => 'AI Enriched',
        RecordStatus.readyToUpload => 'Ready for OSM',
        RecordStatus.uploaded => 'Submitted',
      };

  static RecordStatus fromString(String? value) {
    return RecordStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => RecordStatus.draftOffline,
    );
  }
}

class GeoPoint {
  final double latitude;
  final double longitude;

  const GeoPoint(this.latitude, this.longitude);
}

/// Computes a destination GPS point from a starting coordinate, compass bearing
/// (0..360° clockwise from North), and forward distance in meters.
GeoPoint extrapolateCoordinate({
  required double latitude,
  required double longitude,
  required double bearingDegrees,
  required double distanceMeters,
}) {
  if (distanceMeters <= 0) {
    return GeoPoint(latitude, longitude);
  }

  const earthRadiusMeters = 6371000.0;
  final angularDistance = distanceMeters / earthRadiusMeters;
  final bearingRad = bearingDegrees * math.pi / 180.0;
  final lat1 = latitude * math.pi / 180.0;
  final lon1 = longitude * math.pi / 180.0;

  final sinLat1 = math.sin(lat1);
  final cosLat1 = math.cos(lat1);
  final sinAd = math.sin(angularDistance);
  final cosAd = math.cos(angularDistance);

  final lat2 = math.asin(
    (sinLat1 * cosAd + cosLat1 * sinAd * math.cos(bearingRad)).clamp(-1.0, 1.0),
  );
  final lon2 = lon1 +
      math.atan2(
        math.sin(bearingRad) * sinAd * cosLat1,
        cosAd - sinLat1 * math.sin(lat2),
      );

  return GeoPoint(
    lat2 * 180.0 / math.pi,
    ((lon2 * 180.0 / math.pi) + 540.0) % 360.0 - 180.0,
  );
}

String cardinalDirection(double? headingDegrees) {
  if (headingDegrees == null) return '--';
  const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  final normalized = ((headingDegrees % 360) + 360) % 360;
  final index = ((normalized + 22.5) / 45.0).floor() % 8;
  return dirs[index];
}

/// Per-photo GPS & compass telemetry captured either live at shutter time or
/// extracted from a gallery JPEG's EXIF GPS tags. Allows choosing exactly which
/// photo provides the POI's main coordinates when multiple photos are attached.
class PhotoLocationMeta {
  final String photoPath;
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final double? altitudeMeters;
  final double? headingDegrees;
  final String sourceLabel; // e.g. 'Live GPS', 'Photo EXIF', 'No GPS'
  final DateTime? capturedAt;

  const PhotoLocationMeta({
    required this.photoPath,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.altitudeMeters,
    this.headingDegrees,
    this.sourceLabel = 'Live GPS',
    this.capturedAt,
  });

  bool get hasCoordinates =>
      latitude != null &&
      longitude != null &&
      !latitude!.isNaN &&
      !longitude!.isNaN &&
      (latitude!.abs() >= 0.0001 || longitude!.abs() >= 0.0001) &&
      latitude!.abs() <= 90.0 &&
      longitude!.abs() <= 180.0;

  Map<String, dynamic> toJson() => {
        'photoPath': photoPath,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (accuracyMeters != null) 'accuracyMeters': accuracyMeters,
        if (altitudeMeters != null) 'altitudeMeters': altitudeMeters,
        if (headingDegrees != null) 'headingDegrees': headingDegrees,
        'sourceLabel': sourceLabel,
        if (capturedAt != null) 'capturedAt': capturedAt!.toIso8601String(),
      };

  factory PhotoLocationMeta.fromJson(Map<String, dynamic> json) {
    return PhotoLocationMeta(
      photoPath: json['photoPath']?.toString() ?? '',
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      accuracyMeters: (json['accuracyMeters'] as num?)?.toDouble(),
      altitudeMeters: (json['altitudeMeters'] as num?)?.toDouble(),
      headingDegrees: (json['headingDegrees'] as num?)?.toDouble(),
      sourceLabel: json['sourceLabel']?.toString() ?? 'Live GPS',
      capturedAt: json['capturedAt'] != null
          ? DateTime.tryParse(json['capturedAt'].toString())
          : null,
    );
  }
}

enum PositionUncertaintySeverity {
  highPrecision,
  moderate,
  needsCorrection;

  String get label => switch (this) {
        PositionUncertaintySeverity.highPrecision => 'High Precision',
        PositionUncertaintySeverity.moderate => 'Moderate Error',
        PositionUncertaintySeverity.needsCorrection => 'Check / Correct Pin',
      };
}

/// Transparent breakdown of POI position uncertainty combining:
/// 1. **GPS measurement error** (horizontal accuracy from phone GPS or EXIF)
/// 2. **Spatial calculation error** (distance estimation ±25% + compass ±12° lateral spread)
/// so the user can decide whether to manually adjust the pin on the OSM map.
class PositionUncertainty {
  final double? gpsMeasurementErrorMeters;
  final double distanceCalcErrorMeters;
  final double bearingCalcErrorMeters;
  final double extrapolationCalcErrorMeters;
  final double totalCombinedErrorMeters;
  final bool isManualOverride;
  final PositionUncertaintySeverity severity;

  const PositionUncertainty({
    required this.gpsMeasurementErrorMeters,
    required this.distanceCalcErrorMeters,
    required this.bearingCalcErrorMeters,
    required this.extrapolationCalcErrorMeters,
    required this.totalCombinedErrorMeters,
    required this.isManualOverride,
    required this.severity,
  });

  static PositionUncertainty compute({
    required double? gpsAccuracyMeters,
    required double? headingDegrees,
    required double estimatedOffsetMeters,
    required bool isManualOverride,
  }) {
    if (isManualOverride) {
      return const PositionUncertainty(
        gpsMeasurementErrorMeters: null,
        distanceCalcErrorMeters: 0.0,
        bearingCalcErrorMeters: 0.0,
        extrapolationCalcErrorMeters: 0.0,
        totalCombinedErrorMeters: 2.0,
        isManualOverride: true,
        severity: PositionUncertaintySeverity.highPrecision,
      );
    }

    final validGpsErr =
        gpsAccuracyMeters != null && gpsAccuracyMeters > 0 ? gpsAccuracyMeters : null;
    final assumedGps = validGpsErr ?? 10.0;

    final hasExtrapolation = headingDegrees != null && estimatedOffsetMeters > 0.2;
    // Visual distance estimate has ~25% error (min 1.5m); phone compass has ~12° heading error.
    final distErr = hasExtrapolation
        ? math.max(1.5, estimatedOffsetMeters * 0.25)
        : 0.0;
    final bearingErr = hasExtrapolation
        ? estimatedOffsetMeters * math.sin(12.0 * math.pi / 180.0)
        : 0.0;
    final calcErr = hasExtrapolation
        ? math.sqrt(distErr * distErr + bearingErr * bearingErr)
        : 0.0;

    final totalErr = math.sqrt(assumedGps * assumedGps + calcErr * calcErr);

    final PositionUncertaintySeverity severity;
    if (validGpsErr == null || totalErr > 18.0 || validGpsErr > 20.0) {
      severity = PositionUncertaintySeverity.needsCorrection;
    } else if (totalErr > 8.0) {
      severity = PositionUncertaintySeverity.moderate;
    } else {
      severity = PositionUncertaintySeverity.highPrecision;
    }

    return PositionUncertainty(
      gpsMeasurementErrorMeters: validGpsErr,
      distanceCalcErrorMeters: distErr,
      bearingCalcErrorMeters: bearingErr,
      extrapolationCalcErrorMeters: calcErr,
      totalCombinedErrorMeters: totalErr,
      isManualOverride: false,
      severity: severity,
    );
  }
}

class OsmRecord {
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? photoPath;
  final List<String> photoPaths;
  final List<PhotoLocationMeta> photoLocations;
  final int primaryLocationPhotoIndex;
  final bool isManualPinOverride;
  final double latitude;
  final double longitude;
  final double? accuracyMeters;
  final double? altitudeMeters;
  final double? headingDegrees;
  final double? extrapolatedLatitude;
  final double? extrapolatedLongitude;
  final double estimatedOffsetMeters;
  final String distanceReasoning;
  final String osmType; // node | way | area
  final String summary;
  final String detectedLanguage;
  final Map<String, String> tags;
  final List<String> detectedLabels;
  final Map<String, double> tagCandidates; // "key=value" -> probability 0..1
  final AiSource aiSource;
  final RecordStatus status;
  final String? trailId;
  final String notes;
  final DateTime? firebaseSyncedAt;

  OsmRecord({
    required this.id,
    required this.createdAt,
    DateTime? updatedAt,
    String? photoPath,
    List<String>? photoPaths,
    List<PhotoLocationMeta> photoLocations = const [],
    int primaryLocationPhotoIndex = 0,
    this.isManualPinOverride = false,
    required this.latitude,
    required this.longitude,
    this.accuracyMeters,
    this.altitudeMeters,
    this.headingDegrees,
    this.extrapolatedLatitude,
    this.extrapolatedLongitude,
    this.estimatedOffsetMeters = 6.0,
    this.distanceReasoning = '',
    this.osmType = 'node',
    required this.summary,
    this.detectedLanguage = 'en',
    required this.tags,
    this.detectedLabels = const [],
    this.tagCandidates = const {},
    required this.aiSource,
    required this.status,
    this.trailId,
    this.notes = '',
    this.firebaseSyncedAt,
  })  : updatedAt = updatedAt ?? createdAt,
        photoPaths = _normalizePhotoPaths(photoPath, photoPaths),
        photoPath = _resolvePrimaryPhotoPath(photoPath, photoPaths),
        photoLocations = List.unmodifiable(photoLocations),
        primaryLocationPhotoIndex = _clampPrimaryIndex(
          primaryLocationPhotoIndex,
          _normalizePhotoPaths(photoPath, photoPaths).length,
        );

  static int _clampPrimaryIndex(int idx, int count) {
    if (count <= 0) return 0;
    return idx.clamp(0, count - 1);
  }

  static List<String> _normalizePhotoPaths(
    String? primary,
    List<String>? list,
  ) {
    final result = <String>[];
    void addUnique(String? p) {
      if (p != null && p.trim().isNotEmpty && !result.contains(p)) {
        result.add(p);
      }
    }

    if (list != null && list.isNotEmpty) {
      for (final p in list) {
        addUnique(p);
      }
    }
    if (result.isEmpty) {
      addUnique(primary);
    }
    return List.unmodifiable(result);
  }

  static String? _resolvePrimaryPhotoPath(
    String? primary,
    List<String>? list,
  ) {
    final normalized = _normalizePhotoPaths(primary, list);
    return normalized.isNotEmpty ? normalized.first : null;
  }

  /// All photos attached to this POI (guaranteed non-null list).
  List<String> get allPhotoPaths => photoPaths;
  bool get hasMultiplePhotos => photoPaths.length > 1;

  /// Safe 0-based index of the photo currently providing this POI's main coordinates.
  int get effectivePrimaryPhotoIndex =>
      photoPaths.isEmpty ? 0 : primaryLocationPhotoIndex.clamp(0, photoPaths.length - 1);

  /// Returns stored GPS/compass telemetry for photo at [index], falling back
  /// to this record's primary coordinates for the currently active primary photo.
  PhotoLocationMeta? locationMetaForPhoto(int index) {
    if (index < 0 || index >= photoPaths.length) return null;
    final path = photoPaths[index];
    for (final meta in photoLocations) {
      if (meta.photoPath == path) return meta;
    }
    if (index == effectivePrimaryPhotoIndex) {
      return PhotoLocationMeta(
        photoPath: path,
        latitude: latitude,
        longitude: longitude,
        accuracyMeters: accuracyMeters,
        altitudeMeters: altitudeMeters,
        headingDegrees: headingDegrees,
        sourceLabel: 'Live GPS',
        capturedAt: createdAt,
      );
    }
    return null;
  }

  /// Transparent breakdown of GPS measurement error & spatial extrapolation error.
  PositionUncertainty get positionUncertainty => PositionUncertainty.compute(
        gpsAccuracyMeters: accuracyMeters,
        headingDegrees: headingDegrees,
        estimatedOffsetMeters: estimatedOffsetMeters,
        isManualOverride: isManualPinOverride,
      );

  /// Switches the POI's main coordinate source to photo [index], updating base
  /// GPS/accuracy/heading and recomputing the extrapolated POI coordinates.
  OsmRecord selectMainLocationPhoto(int index) {
    if (photoPaths.isEmpty) return this;
    final safeIdx = index.clamp(0, photoPaths.length - 1);
    final meta = locationMetaForPhoto(safeIdx);
    final nextLat = (meta != null && meta.hasCoordinates) ? meta.latitude! : latitude;
    final nextLon = (meta != null && meta.hasCoordinates) ? meta.longitude! : longitude;
    final nextAcc = (meta != null && meta.hasCoordinates)
        ? meta.accuracyMeters
        : accuracyMeters;
    final nextAlt = (meta != null && meta.hasCoordinates)
        ? (meta.altitudeMeters ?? altitudeMeters)
        : altitudeMeters;
    final nextHeading = (meta != null && meta.hasCoordinates)
        ? meta.headingDegrees
        : headingDegrees;

    final extrap = nextHeading != null
        ? extrapolateCoordinate(
            latitude: nextLat,
            longitude: nextLon,
            bearingDegrees: nextHeading,
            distanceMeters: estimatedOffsetMeters,
          )
        : GeoPoint(nextLat, nextLon);

    return copyWith(
      primaryLocationPhotoIndex: safeIdx,
      isManualPinOverride: false,
      latitude: nextLat,
      longitude: nextLon,
      accuracyMeters: nextAcc,
      clearAccuracyMeters: nextAcc == null,
      altitudeMeters: nextAlt,
      headingDegrees: nextHeading,
      clearHeadingDegrees: nextHeading == null,
      extrapolatedLatitude: extrap.latitude,
      extrapolatedLongitude: extrap.longitude,
    );
  }

  /// Applies a user-corrected POI pin location directly (e.g. tapped on OSM map).
  OsmRecord withManualPinCoordinates(double lat, double lon) {
    return copyWith(
      extrapolatedLatitude: lat,
      extrapolatedLongitude: lon,
      isManualPinOverride: true,
      distanceReasoning: 'Manually corrected pin on OSM map',
    );
  }

  double get effectiveLatitude => extrapolatedLatitude ?? latitude;
  double get effectiveLongitude => extrapolatedLongitude ?? longitude;
  bool get isSyncedToFirebase => firebaseSyncedAt != null;

  String get displayName {
    final name = tags['name'] ?? tags['name:en'];
    if (name != null && name.trim().isNotEmpty) return name.trim();
    if (summary.trim().isNotEmpty) return summary.trim();
    return 'Unnamed OSM Feature';
  }

  String get primaryCategoryTag {
    const priorityKeys = [
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
    for (final key in priorityKeys) {
      final value = tags[key];
      if (value != null && value.isNotEmpty) {
        return '$key=$value';
      }
    }
    return tags.isNotEmpty
        ? '${tags.entries.first.key}=${tags.entries.first.value}'
        : 'unclassified';
  }

  bool get hasMultilingualTags =>
      tags.keys.any((k) => k.startsWith('name:') && k.length > 5);

  OsmRecord copyWith({
    String? id,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? photoPath,
    List<String>? photoPaths,
    List<PhotoLocationMeta>? photoLocations,
    int? primaryLocationPhotoIndex,
    bool? isManualPinOverride,
    double? latitude,
    double? longitude,
    double? accuracyMeters,
    bool clearAccuracyMeters = false,
    double? altitudeMeters,
    double? headingDegrees,
    bool clearHeadingDegrees = false,
    double? extrapolatedLatitude,
    double? extrapolatedLongitude,
    double? estimatedOffsetMeters,
    String? distanceReasoning,
    String? osmType,
    String? summary,
    String? detectedLanguage,
    Map<String, String>? tags,
    List<String>? detectedLabels,
    Map<String, double>? tagCandidates,
    AiSource? aiSource,
    RecordStatus? status,
    String? trailId,
    String? notes,
    DateTime? firebaseSyncedAt,
    bool clearFirebaseSyncedAt = false,
  }) {
    final resolvedPhotoPaths = photoPaths ??
        (photoPath != null && photoPath != this.photoPath
            ? [
                photoPath,
                ...this.photoPaths.where((p) => p != photoPath),
              ]
            : this.photoPaths);
    return OsmRecord(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      photoPath: photoPath ??
          (resolvedPhotoPaths.isNotEmpty ? resolvedPhotoPaths.first : null),
      photoPaths: resolvedPhotoPaths,
      photoLocations: photoLocations ?? this.photoLocations,
      primaryLocationPhotoIndex:
          primaryLocationPhotoIndex ?? this.primaryLocationPhotoIndex,
      isManualPinOverride: isManualPinOverride ?? this.isManualPinOverride,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      accuracyMeters: clearAccuracyMeters
          ? null
          : (accuracyMeters ?? this.accuracyMeters),
      altitudeMeters: altitudeMeters ?? this.altitudeMeters,
      headingDegrees: clearHeadingDegrees
          ? null
          : (headingDegrees ?? this.headingDegrees),
      extrapolatedLatitude: extrapolatedLatitude ?? this.extrapolatedLatitude,
      extrapolatedLongitude:
          extrapolatedLongitude ?? this.extrapolatedLongitude,
      estimatedOffsetMeters:
          estimatedOffsetMeters ?? this.estimatedOffsetMeters,
      distanceReasoning: distanceReasoning ?? this.distanceReasoning,
      osmType: osmType ?? this.osmType,
      summary: summary ?? this.summary,
      detectedLanguage: detectedLanguage ?? this.detectedLanguage,
      tags: tags ?? Map<String, String>.from(this.tags),
      detectedLabels: detectedLabels ?? List<String>.from(this.detectedLabels),
      tagCandidates:
          tagCandidates ?? Map<String, double>.from(this.tagCandidates),
      aiSource: aiSource ?? this.aiSource,
      status: status ?? this.status,
      trailId: trailId ?? this.trailId,
      notes: notes ?? this.notes,
      firebaseSyncedAt: clearFirebaseSyncedAt
          ? null
          : (firebaseSyncedAt ?? this.firebaseSyncedAt),
    );
  }

  Map<String, Object?> toDbMap() {
    return {
      'id': id,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'photo_path': photoPath,
      'photo_paths_json': jsonEncode(photoPaths),
      'photo_locations_json':
          jsonEncode(photoLocations.map((m) => m.toJson()).toList()),
      'primary_location_photo_index': primaryLocationPhotoIndex,
      'is_manual_pin_override': isManualPinOverride ? 1 : 0,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy_meters': accuracyMeters,
      'altitude_meters': altitudeMeters,
      'heading_degrees': headingDegrees,
      'extrapolated_lat': extrapolatedLatitude,
      'extrapolated_lon': extrapolatedLongitude,
      'estimated_offset_meters': estimatedOffsetMeters,
      'distance_reasoning': distanceReasoning,
      'osm_type': osmType,
      'summary': summary,
      'detected_language': detectedLanguage,
      'tags_json': jsonEncode(tags),
      'detected_labels_json': jsonEncode(detectedLabels),
      'tag_candidates_json': jsonEncode(tagCandidates),
      'ai_source': aiSource.name,
      'status': status.name,
      'trail_id': trailId,
      'notes': notes,
      'firebase_synced_at': firebaseSyncedAt?.toIso8601String(),
    };
  }

  factory OsmRecord.fromDbMap(Map<String, Object?> map) {
    final rawTags = map['tags_json'] as String? ?? '{}';
    final decoded = jsonDecode(rawTags) as Map<String, dynamic>;

    List<String> labels = const [];
    final rawLabels = map['detected_labels_json'] as String?;
    if (rawLabels != null && rawLabels.isNotEmpty) {
      try {
        labels = (jsonDecode(rawLabels) as List)
            .map((e) => e.toString())
            .toList();
      } catch (_) {}
    }

    List<String>? photoPaths;
    final rawPhotoPaths = map['photo_paths_json'] as String?;
    if (rawPhotoPaths != null && rawPhotoPaths.isNotEmpty) {
      try {
        photoPaths = (jsonDecode(rawPhotoPaths) as List)
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList();
      } catch (_) {}
    }

    final photoLocations = <PhotoLocationMeta>[];
    final rawPhotoLocs = map['photo_locations_json'] as String?;
    if (rawPhotoLocs != null && rawPhotoLocs.isNotEmpty) {
      try {
        for (final item in (jsonDecode(rawPhotoLocs) as List)) {
          if (item is Map) {
            photoLocations.add(
              PhotoLocationMeta.fromJson(Map<String, dynamic>.from(item)),
            );
          }
        }
      } catch (_) {}
    }

    Map<String, double> candidates = const {};
    final rawCandidates = map['tag_candidates_json'] as String?;
    if (rawCandidates != null && rawCandidates.isNotEmpty) {
      try {
        final decodedCandidates =
            jsonDecode(rawCandidates) as Map<String, dynamic>;
        candidates = decodedCandidates.map(
          (k, v) => MapEntry(k, (v as num).toDouble()),
        );
      } catch (_) {}
    }

    final rawSynced = map['firebase_synced_at'] as String?;
    final parsedCreatedAt = DateTime.parse(map['created_at'] as String);
    final rawUpdated = map['updated_at'] as String?;
    final parsedUpdatedAt = rawUpdated != null && rawUpdated.isNotEmpty
        ? (DateTime.tryParse(rawUpdated) ?? parsedCreatedAt)
        : parsedCreatedAt;

    return OsmRecord(
      id: map['id'] as String,
      createdAt: parsedCreatedAt,
      updatedAt: parsedUpdatedAt,
      photoPath: map['photo_path'] as String?,
      photoPaths: photoPaths,
      photoLocations: photoLocations,
      primaryLocationPhotoIndex:
          (map['primary_location_photo_index'] as num?)?.toInt() ?? 0,
      isManualPinOverride: (map['is_manual_pin_override'] as num?)?.toInt() == 1,
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      accuracyMeters: (map['accuracy_meters'] as num?)?.toDouble(),
      altitudeMeters: (map['altitude_meters'] as num?)?.toDouble(),
      headingDegrees: (map['heading_degrees'] as num?)?.toDouble(),
      extrapolatedLatitude: (map['extrapolated_lat'] as num?)?.toDouble(),
      extrapolatedLongitude: (map['extrapolated_lon'] as num?)?.toDouble(),
      estimatedOffsetMeters:
          (map['estimated_offset_meters'] as num?)?.toDouble() ?? 6.0,
      distanceReasoning: map['distance_reasoning'] as String? ?? '',
      osmType: map['osm_type'] as String? ?? 'node',
      summary: map['summary'] as String? ?? '',
      detectedLanguage: map['detected_language'] as String? ?? 'en',
      tags: decoded.map((k, v) => MapEntry(k, v.toString())),
      detectedLabels: labels,
      tagCandidates: candidates,
      aiSource: AiSource.fromString(map['ai_source'] as String?),
      status: RecordStatus.fromString(map['status'] as String?),
      trailId: map['trail_id'] as String?,
      notes: map['notes'] as String? ?? '',
      firebaseSyncedAt:
          rawSynced != null && rawSynced.isNotEmpty ? DateTime.tryParse(rawSynced) : null,
    );
  }
}
