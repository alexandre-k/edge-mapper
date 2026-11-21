import 'dart:convert';
import 'dart:math' as math;

enum ActivityType {
  urbanWalk,
  parkStroll,
  hiking,
  natureWalk,
  cycling,
  running,
  wheelchair,
  stairway,
  sharedTrack;

  String get label => switch (this) {
        ActivityType.urbanWalk => 'City / Street Walk',
        ActivityType.parkStroll => 'Park Stroll',
        ActivityType.hiking => 'Mountain Hike',
        ActivityType.natureWalk => 'Nature / Forest Walk',
        ActivityType.cycling => 'Cycling Route',
        ActivityType.running => 'Jog / Run',
        ActivityType.wheelchair => 'Accessible Route',
        ActivityType.stairway => 'Stairs / Steps',
        ActivityType.sharedTrack => 'Rural / Farm Track',
      };

  String get shortLabel => switch (this) {
        ActivityType.urbanWalk => 'City Walk',
        ActivityType.parkStroll => 'Park',
        ActivityType.hiking => 'Hike',
        ActivityType.natureWalk => 'Nature',
        ActivityType.cycling => 'Bike',
        ActivityType.running => 'Run',
        ActivityType.wheelchair => 'Accessible',
        ActivityType.stairway => 'Steps',
        ActivityType.sharedTrack => 'Track',
      };

  String get defaultHighway => switch (this) {
        ActivityType.urbanWalk => 'footway',
        ActivityType.parkStroll => 'footway',
        ActivityType.hiking => 'path',
        ActivityType.natureWalk => 'path',
        ActivityType.cycling => 'cycleway',
        ActivityType.running => 'path',
        ActivityType.wheelchair => 'footway',
        ActivityType.stairway => 'steps',
        ActivityType.sharedTrack => 'track',
      };

  String get defaultSurface => switch (this) {
        ActivityType.urbanWalk => 'paved',
        ActivityType.parkStroll => 'compacted',
        ActivityType.hiking => 'ground',
        ActivityType.natureWalk => 'dirt',
        ActivityType.cycling => 'asphalt',
        ActivityType.running => 'gravel',
        ActivityType.wheelchair => 'asphalt',
        ActivityType.stairway => 'concrete',
        ActivityType.sharedTrack => 'gravel',
      };

  Map<String, String> get defaultTags => switch (this) {
        ActivityType.urbanWalk => {
            'highway': 'footway',
            'surface': 'paved',
            'foot': 'yes',
          },
        ActivityType.parkStroll => {
            'highway': 'footway',
            'surface': 'compacted',
            'foot': 'yes',
            'informal': 'no',
          },
        ActivityType.hiking => {
            'highway': 'path',
            'surface': 'ground',
            'foot': 'yes',
            'sac_scale': 'hiking',
          },
        ActivityType.natureWalk => {
            'highway': 'path',
            'surface': 'dirt',
            'foot': 'yes',
          },
        ActivityType.cycling => {
            'highway': 'cycleway',
            'surface': 'asphalt',
            'bicycle': 'designated',
          },
        ActivityType.running => {
            'highway': 'path',
            'surface': 'gravel',
            'foot': 'yes',
          },
        ActivityType.wheelchair => {
            'highway': 'footway',
            'surface': 'asphalt',
            'wheelchair': 'yes',
            'smoothness': 'good',
          },
        ActivityType.stairway => {
            'highway': 'steps',
            'surface': 'concrete',
            'foot': 'yes',
          },
        ActivityType.sharedTrack => {
            'highway': 'track',
            'surface': 'gravel',
            'foot': 'yes',
          },
      };

  static ActivityType fromString(String? value) {
    return ActivityType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ActivityType.hiking,
    );
  }
}

class TrailPoint {
  final int? id;
  final String trailId;
  final double latitude;
  final double longitude;
  final double? altitudeMeters;
  final double? accuracyMeters;
  final DateTime recordedAt;

  const TrailPoint({
    this.id,
    required this.trailId,
    required this.latitude,
    required this.longitude,
    this.altitudeMeters,
    this.accuracyMeters,
    required this.recordedAt,
  });

  Map<String, Object?> toDbMap() {
    return {
      if (id != null) 'id': id,
      'trail_id': trailId,
      'latitude': latitude,
      'longitude': longitude,
      'altitude_meters': altitudeMeters,
      'accuracy_meters': accuracyMeters,
      'recorded_at': recordedAt.toIso8601String(),
    };
  }

  factory TrailPoint.fromDbMap(Map<String, Object?> map) {
    return TrailPoint(
      id: map['id'] as int?,
      trailId: map['trail_id'] as String,
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      altitudeMeters: (map['altitude_meters'] as num?)?.toDouble(),
      accuracyMeters: (map['accuracy_meters'] as num?)?.toDouble(),
      recordedAt: DateTime.parse(map['recorded_at'] as String),
    );
  }
}

class HikeTrail {
  final String id;
  final String name;
  final DateTime startedAt;
  final DateTime? endedAt;
  final bool isActive;
  final ActivityType activityType;
  final Map<String, String> tags;
  final List<TrailPoint> points;
  final bool needsLocationGuess;
  final String locationContext;
  final DateTime? firebaseSyncedAt;

  const HikeTrail({
    required this.id,
    required this.name,
    required this.startedAt,
    this.endedAt,
    required this.isActive,
    this.activityType = ActivityType.hiking,
    required this.tags,
    this.points = const [],
    this.needsLocationGuess = false,
    this.locationContext = '',
    this.firebaseSyncedAt,
  });

  bool get isSyncedToFirebase => firebaseSyncedAt != null;

  Duration get duration {
    final end = endedAt ?? DateTime.now();
    return end.difference(startedAt);
  }

  double get totalDistanceMeters {
    if (points.length < 2) return 0.0;
    double sum = 0.0;
    for (var i = 1; i < points.length; i++) {
      sum += haversineMeters(
        points[i - 1].latitude,
        points[i - 1].longitude,
        points[i].latitude,
        points[i].longitude,
      );
    }
    return sum;
  }

  double get elevationGainMeters {
    if (points.length < 2) return 0.0;
    double gain = 0.0;
    for (var i = 1; i < points.length; i++) {
      final prev = points[i - 1].altitudeMeters;
      final curr = points[i].altitudeMeters;
      if (prev != null && curr != null && curr - prev > 1.0) {
        gain += (curr - prev);
      }
    }
    return gain;
  }

  double get elevationLossMeters {
    if (points.length < 2) return 0.0;
    double loss = 0.0;
    for (var i = 1; i < points.length; i++) {
      final prev = points[i - 1].altitudeMeters;
      final curr = points[i].altitudeMeters;
      if (prev != null && curr != null && prev - curr > 1.0) {
        loss += (prev - curr);
      }
    }
    return loss;
  }

  double? get averageAccuracyMeters {
    final valid = points
        .map((p) => p.accuracyMeters)
        .whereType<double>()
        .toList();
    if (valid.isEmpty) return null;
    return valid.reduce((a, b) => a + b) / valid.length;
  }

  /// Counts consecutive segment jumps that look like GPS glitches (> 45 m/s or > 150m in <= 3s).
  int get suspectJumpCount {
    if (points.length < 2) return 0;
    int jumps = 0;
    for (var i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final curr = points[i];
      final dist = haversineMeters(
        prev.latitude,
        prev.longitude,
        curr.latitude,
        curr.longitude,
      );
      final dtSec = math.max(
        curr.recordedAt.difference(prev.recordedAt).inMilliseconds / 1000.0,
        0.5,
      );
      final speedMps = dist / dtSec;
      if (speedMps > 45.0 || (dist > 150.0 && dtSec <= 3.0)) {
        jumps++;
      }
    }
    return jumps;
  }

  double get averageSpeedKmh {
    final secs = duration.inSeconds;
    if (secs <= 0 || totalDistanceMeters <= 0) return 0.0;
    return (totalDistanceMeters / 1000.0) / (secs / 3600.0);
  }

  HikeTrail copyWith({
    String? id,
    String? name,
    DateTime? startedAt,
    DateTime? endedAt,
    bool? isActive,
    ActivityType? activityType,
    Map<String, String>? tags,
    List<TrailPoint>? points,
    bool? needsLocationGuess,
    String? locationContext,
    DateTime? firebaseSyncedAt,
    bool clearFirebaseSyncedAt = false,
  }) {
    return HikeTrail(
      id: id ?? this.id,
      name: name ?? this.name,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      isActive: isActive ?? this.isActive,
      activityType: activityType ?? this.activityType,
      tags: tags ?? Map<String, String>.from(this.tags),
      points: points ?? List<TrailPoint>.from(this.points),
      needsLocationGuess: needsLocationGuess ?? this.needsLocationGuess,
      locationContext: locationContext ?? this.locationContext,
      firebaseSyncedAt: clearFirebaseSyncedAt
          ? null
          : (firebaseSyncedAt ?? this.firebaseSyncedAt),
    );
  }

  Map<String, Object?> toDbMap() {
    return {
      'id': id,
      'name': name,
      'started_at': startedAt.toIso8601String(),
      'ended_at': endedAt?.toIso8601String(),
      'is_active': isActive ? 1 : 0,
      'activity_type': activityType.name,
      'tags_json': jsonEncode(tags),
      'needs_location_guess': needsLocationGuess ? 1 : 0,
      'location_context': locationContext,
      'firebase_synced_at': firebaseSyncedAt?.toIso8601String(),
    };
  }

  factory HikeTrail.fromDbMap(
    Map<String, Object?> map, {
    List<TrailPoint> points = const [],
  }) {
    final rawTags = map['tags_json'] as String? ?? '{}';
    final decoded = jsonDecode(rawTags) as Map<String, dynamic>;
    final rawSynced = map['firebase_synced_at'] as String?;
    return HikeTrail(
      id: map['id'] as String,
      name: map['name'] as String,
      startedAt: DateTime.parse(map['started_at'] as String),
      endedAt: map['ended_at'] != null
          ? DateTime.parse(map['ended_at'] as String)
          : null,
      isActive: (map['is_active'] as int? ?? 0) == 1,
      activityType: ActivityType.fromString(map['activity_type'] as String?),
      tags: decoded.map((k, v) => MapEntry(k, v.toString())),
      points: points,
      needsLocationGuess: (map['needs_location_guess'] as int? ?? 0) == 1,
      locationContext: map['location_context'] as String? ?? '',
      firebaseSyncedAt:
          rawSynced != null && rawSynced.isNotEmpty ? DateTime.tryParse(rawSynced) : null,
    );
  }
}

double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusMeters = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLon = (lon2 - lon1) * math.pi / 180.0;
  final rLat1 = lat1 * math.pi / 180.0;
  final rLat2 = lat2 * math.pi / 180.0;

  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rLat1) *
          math.cos(rLat2) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusMeters * c;
}
