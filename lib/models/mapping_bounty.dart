import 'dart:convert';

enum BountyStatus {
  open,
  claimed,
  paid;

  String get label => switch (this) {
        BountyStatus.open => 'Open',
        BountyStatus.claimed => 'Pending Payout',
        BountyStatus.paid => 'Paid in BTC',
      };

  static BountyStatus fromString(String? value) {
    return BountyStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => BountyStatus.open,
    );
  }
}

class BountySubmission {
  final String submissionId;
  final String mapperExplorerId;
  final String mapperName;
  final String mapperBtcAddress;
  final String recordId;
  final String recordSummary;
  final DateTime submittedAt;
  final double? distanceMeters;
  final DateTime? paidAt;

  const BountySubmission({
    required this.submissionId,
    required this.mapperExplorerId,
    required this.mapperName,
    required this.mapperBtcAddress,
    required this.recordId,
    required this.recordSummary,
    required this.submittedAt,
    this.distanceMeters,
    this.paidAt,
  });

  bool get isPaid => paidAt != null;

  BountySubmission copyWith({
    DateTime? paidAt,
  }) {
    return BountySubmission(
      submissionId: submissionId,
      mapperExplorerId: mapperExplorerId,
      mapperName: mapperName,
      mapperBtcAddress: mapperBtcAddress,
      recordId: recordId,
      recordSummary: recordSummary,
      submittedAt: submittedAt,
      distanceMeters: distanceMeters,
      paidAt: paidAt ?? this.paidAt,
    );
  }

  Map<String, Object?> toJson() => {
        'submissionId': submissionId,
        'mapperExplorerId': mapperExplorerId,
        'mapperName': mapperName,
        'mapperBtcAddress': mapperBtcAddress,
        'recordId': recordId,
        'recordSummary': recordSummary,
        'submittedAt': submittedAt.toIso8601String(),
        'distanceMeters': distanceMeters,
        'paidAt': paidAt?.toIso8601String(),
      };

  factory BountySubmission.fromJson(Map<String, dynamic> json) {
    return BountySubmission(
      submissionId: json['submissionId']?.toString() ?? '',
      mapperExplorerId: json['mapperExplorerId']?.toString() ?? '',
      mapperName: json['mapperName']?.toString() ?? 'Explorer',
      mapperBtcAddress: json['mapperBtcAddress']?.toString() ?? '',
      recordId: json['recordId']?.toString() ?? '',
      recordSummary: json['recordSummary']?.toString() ?? '',
      submittedAt: DateTime.tryParse(json['submittedAt']?.toString() ?? '') ??
          DateTime.now(),
      distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
      paidAt: json['paidAt'] != null
          ? DateTime.tryParse(json['paidAt'].toString())
          : null,
    );
  }
}

/// Social mapping announcement with a Bitcoin (sats) reward for mappers who
/// survey a requested area/POI.
class MappingBounty {
  final String id;
  final String title;
  final String description;
  final String areaLabel;
  final double targetLatitude;
  final double targetLongitude;
  final double radiusMeters;
  final List<String> requestedTags;
  final int rewardSats;
  final String creatorExplorerId;
  final String creatorName;
  final DateTime createdAt;
  final BountyStatus status;
  final List<BountySubmission> submissions;

  const MappingBounty({
    required this.id,
    required this.title,
    required this.description,
    required this.areaLabel,
    required this.targetLatitude,
    required this.targetLongitude,
    this.radiusMeters = 350.0,
    this.requestedTags = const [],
    required this.rewardSats,
    required this.creatorExplorerId,
    required this.creatorName,
    required this.createdAt,
    this.status = BountyStatus.open,
    this.submissions = const [],
  });

  double get rewardBtc => rewardSats / 100000000.0;

  MappingBounty copyWith({
    String? title,
    String? description,
    String? areaLabel,
    double? targetLatitude,
    double? targetLongitude,
    double? radiusMeters,
    List<String>? requestedTags,
    int? rewardSats,
    BountyStatus? status,
    List<BountySubmission>? submissions,
  }) {
    return MappingBounty(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      areaLabel: areaLabel ?? this.areaLabel,
      targetLatitude: targetLatitude ?? this.targetLatitude,
      targetLongitude: targetLongitude ?? this.targetLongitude,
      radiusMeters: radiusMeters ?? this.radiusMeters,
      requestedTags: requestedTags ?? List<String>.from(this.requestedTags),
      rewardSats: rewardSats ?? this.rewardSats,
      creatorExplorerId: creatorExplorerId,
      creatorName: creatorName,
      createdAt: createdAt,
      status: status ?? this.status,
      submissions: submissions ?? List<BountySubmission>.from(this.submissions),
    );
  }

  Map<String, Object?> toDbMap() => {
        'id': id,
        'title': title,
        'description': description,
        'area_label': areaLabel,
        'target_lat': targetLatitude,
        'target_lon': targetLongitude,
        'radius_meters': radiusMeters,
        'requested_tags_json': jsonEncode(requestedTags),
        'reward_sats': rewardSats,
        'creator_explorer_id': creatorExplorerId,
        'creator_name': creatorName,
        'created_at': createdAt.toIso8601String(),
        'status': status.name,
        'require_proof': 0,
        'submissions_json':
            jsonEncode(submissions.map((s) => s.toJson()).toList()),
      };

  factory MappingBounty.fromDbMap(Map<String, Object?> map) {
    List<String> tags = const [];
    try {
      final raw = map['requested_tags_json'] as String?;
      if (raw != null && raw.isNotEmpty) {
        tags = (jsonDecode(raw) as List).map((e) => e.toString()).toList();
      }
    } catch (_) {}

    List<BountySubmission> subs = const [];
    try {
      final raw = map['submissions_json'] as String?;
      if (raw != null && raw.isNotEmpty) {
        subs = (jsonDecode(raw) as List)
            .whereType<Map>()
            .map((e) => BountySubmission.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {}

    return MappingBounty(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? 'Mapping Request',
      description: map['description']?.toString() ?? '',
      areaLabel: map['area_label']?.toString() ?? '',
      targetLatitude: (map['target_lat'] as num?)?.toDouble() ?? 0.0,
      targetLongitude: (map['target_lon'] as num?)?.toDouble() ?? 0.0,
      radiusMeters: (map['radius_meters'] as num?)?.toDouble() ?? 350.0,
      requestedTags: tags,
      rewardSats: (map['reward_sats'] as num?)?.toInt() ?? 0,
      creatorExplorerId: map['creator_explorer_id']?.toString() ?? '',
      creatorName: map['creator_name']?.toString() ?? 'Explorer',
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? '') ??
          DateTime.now(),
      status: BountyStatus.fromString(map['status']?.toString()),
      submissions: subs,
    );
  }
}
