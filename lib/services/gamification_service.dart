import 'package:flutter/material.dart';

import '../models/hike_trail.dart';
import '../models/osm_record.dart';
import 'explorer_avatar_service.dart';

class ExplorerBadge {
  final String id;
  final String title;
  final String description;
  final IconData icon;
  final Color color;
  final bool unlocked;

  const ExplorerBadge({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
    required this.unlocked,
  });
}

class ExplorerProfile {
  final int xp;
  final int level;
  final String rankTitle;
  final int xpIntoLevel;
  final int xpForNextLevel;
  final int activeDayStreak;
  final List<ExplorerBadge> badges;
  final String dailyTip;
  final ExplorerAvatarProfile avatar;

  const ExplorerProfile({
    required this.xp,
    required this.level,
    required this.rankTitle,
    required this.xpIntoLevel,
    required this.xpForNextLevel,
    required this.activeDayStreak,
    required this.badges,
    required this.dailyTip,
    required this.avatar,
  });

  double get levelProgress =>
      xpForNextLevel > 0 ? (xpIntoLevel / xpForNextLevel).clamp(0.0, 1.0) : 1.0;

  int get unlockedBadgeCount => badges.where((b) => b.unlocked).length;
}

/// Turns field mapping into an encouraging, joyful RPG adventure with Explorer XP,
/// ranks, unique procedural avatars, funny nicknames, RPG stats/characteristics,
/// streaks, and unlockable badges computed from local records & routes.
class GamificationService {
  static const List<String> _ranks = [
    'Trail Rookie',
    'Street Scout',
    'Pathfinder',
    'Cartographer',
    'Field Explorer',
    'Atlas Artisan',
    'World Builder',
    'OSM Legend',
  ];

  static const List<String> _tips = [
    'Snap a local cafe or bench to earn +25 XP!',
    'Add 2+ angles of a shop for AI Multi-Photo Merge (+10 bonus XP)!',
    'Add a bilingual tag (name:<lang>) for +10 bonus XP!',
    'Take a stroll in a park & map the path for +30 XP/km!',
    'Capture with live GPS for a verified cryptographic proof (+10 XP)!',
    'Check the Community tab to climb the ranking or claim a Bitcoin bounty!',
  ];

  /// Computes level from raw XP using progressive thresholds (100, 150, 200, ...).
  static int levelForXp(int xp) {
    int level = 1;
    int remaining = xp;
    int threshold = 100;
    while (remaining >= threshold) {
      remaining -= threshold;
      level++;
      threshold = 100 + (level - 1) * 50;
    }
    return level;
  }

  static ExplorerProfile computeProfile({
    required List<OsmRecord> records,
    required List<HikeTrail> trails,
    String avatarSeed = 'edge-mapper-default',
    int completedBountiesCount = 0,
  }) {
    int xp = completedBountiesCount * 60;
    int multiPhotoCount = 0;
    int multilingualCount = 0;
    int offlineCount = 0;

    for (final r in records) {
      xp += 25; // Base capture XP
      if (r.status == RecordStatus.aiEnriched ||
          r.status == RecordStatus.readyToUpload ||
          r.status == RecordStatus.uploaded) {
        xp += 15;
      }
      if (r.hasMultilingualTags) {
        xp += 10;
        multilingualCount++;
      }
      if (r.tags.length >= 5) {
        xp += 10;
      }
      if (r.isSyncedToFirebase) {
        xp += 10;
      }
      if (r.hasMultiplePhotos) {
        xp += 10;
        multiPhotoCount++;
      }
      if (r.aiSource == AiSource.mlKitOffline ||
          r.aiSource == AiSource.geminiNano) {
        offlineCount++;
      }
    }

    double totalMeters = 0;
    for (final t in trails) {
      totalMeters += t.totalDistanceMeters;
      if (!t.isActive) xp += 20;
      xp += ((t.totalDistanceMeters / 1000.0) * 30).round();
      if (t.isSyncedToFirebase) xp += 10;
    }

    // Progressive level thresholds: 100, 150, 200, 250...
    int level = 1;
    int remaining = xp;
    int threshold = 100;
    while (remaining >= threshold) {
      remaining -= threshold;
      level++;
      threshold = 100 + (level - 1) * 50;
    }

    final rankTitle = _ranks[(level - 1).clamp(0, _ranks.length - 1)];

    // Compute unique mapping days streak
    final activeDays = <DateTime>{};
    for (final r in records) {
      activeDays.add(
        DateTime(r.createdAt.year, r.createdAt.month, r.createdAt.day),
      );
    }
    for (final t in trails) {
      activeDays.add(
        DateTime(t.startedAt.year, t.startedAt.month, t.startedAt.day),
      );
    }
    int streak = 0;
    if (activeDays.isNotEmpty) {
      final today = DateTime.now();
      var cursor = DateTime(today.year, today.month, today.day);
      if (!activeDays.contains(cursor)) {
        cursor = cursor.subtract(const Duration(days: 1));
      }
      while (activeDays.contains(cursor)) {
        streak++;
        cursor = cursor.subtract(const Duration(days: 1));
      }
    }

    final hasMultilingual = multilingualCount > 0;
    final hasOfflineCapture = offlineCount > 0;
    final hasParkWalk = trails.any(
      (t) =>
          t.activityType == ActivityType.parkStroll ||
          t.activityType == ActivityType.urbanWalk,
    );
    final hasRichTagRecord = records.any((r) => r.tags.length >= 5);
    final hasCloudBackup = records.any((r) => r.isSyncedToFirebase) ||
        trails.any((t) => t.isSyncedToFirebase);

    final badges = <ExplorerBadge>[
      ExplorerBadge(
        id: 'first_pin',
        title: 'First Pin!',
        description: 'Capture your very first OpenStreetMap place.',
        icon: Icons.push_pin_rounded,
        color: const Color(0xFF10B981),
        unlocked: records.isNotEmpty,
      ),
      ExplorerBadge(
        id: 'multi_angle',
        title: 'Multi-Angle Pro',
        description: 'Merge 2+ photos of a POI together with AI.',
        icon: Icons.collections_rounded,
        color: const Color(0xFF0EA5E9),
        unlocked: multiPhotoCount > 0,
      ),
      ExplorerBadge(
        id: 'polyglot',
        title: 'Polyglot Mapper',
        description: 'Tag a place with multilingual name:<lang> tags.',
        icon: Icons.translate_rounded,
        color: const Color(0xFF6366F1),
        unlocked: hasMultilingual,
      ),
      ExplorerBadge(
        id: 'trailblazer',
        title: 'Trailblazer',
        description: 'Finish recording a walk, park stroll, or hike.',
        icon: Icons.route_rounded,
        color: const Color(0xFFF59E0B),
        unlocked: trails.any((t) => !t.isActive),
      ),
      ExplorerBadge(
        id: 'park_wanderer',
        title: 'Park Wanderer',
        description: 'Record a park stroll or neighborhood city walk.',
        icon: Icons.park_rounded,
        color: const Color(0xFF22C55E),
        unlocked: hasParkWalk,
      ),
      ExplorerBadge(
        id: 'off_grid',
        title: 'Off-Grid Explorer',
        description: 'Map a place 100% offline with on-device vision.',
        icon: Icons.explore_rounded,
        color: const Color(0xFFF97316),
        unlocked: hasOfflineCapture,
      ),
      ExplorerBadge(
        id: 'detail_pro',
        title: 'Precision Scout',
        description: 'Add 5 or more rich OSM tags to a single place.',
        icon: Icons.verified_rounded,
        color: const Color(0xFF0284C7),
        unlocked: hasRichTagRecord,
      ),
      ExplorerBadge(
        id: 'distance_1k',
        title: 'Kilometer Club',
        description: 'Record 1.0 km or more of total mapped routes.',
        icon: Icons.directions_walk_rounded,
        color: const Color(0xFFEC4899),
        unlocked: totalMeters >= 1000.0,
      ),
      ExplorerBadge(
        id: 'cloud_archivist',
        title: 'Cloud Archivist',
        description: 'Save your field records or routes to Firebase.',
        icon: Icons.cloud_done_rounded,
        color: const Color(0xFF8B5CF6),
        unlocked: hasCloudBackup,
      ),
    ];

    final avatar = ExplorerAvatarService.buildAvatar(
      seed: avatarSeed,
      level: level,
      xp: xp,
      recordsCount: records.length,
      multiPhotoRecordsCount: multiPhotoCount,
      multilingualRecordsCount: multilingualCount,
      offlineRecordsCount: offlineCount,
      totalTrailKm: totalMeters / 1000.0,
      activeDayStreak: streak,
    );

    final tipIndex = (records.length + trails.length) % _tips.length;

    return ExplorerProfile(
      xp: xp,
      level: level,
      rankTitle: rankTitle,
      xpIntoLevel: remaining,
      xpForNextLevel: threshold,
      activeDayStreak: streak,
      badges: badges,
      dailyTip: _tips[tipIndex],
      avatar: avatar,
    );
  }
}
