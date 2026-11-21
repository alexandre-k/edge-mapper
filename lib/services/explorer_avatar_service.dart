import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

class RpgCharacteristic {
  final String id;
  final String name;
  final String bonusText;
  final String description;
  final int unlockedAtLevel;
  final IconData icon;
  final Color color;

  const RpgCharacteristic({
    required this.id,
    required this.name,
    required this.bonusText,
    required this.description,
    required this.unlockedAtLevel,
    required this.icon,
    required this.color,
  });
}

class RpgStats {
  final int perception; // Photo & multi-photo capture sharpness
  final int stamina; // Distance walked/hiked & streak endurance
  final int linguistics; // Multilingual OSM name tagging
  final int stealth; // Off-grid / offline mapping capability
  final int integrity; // Cryptographic proofs & verified uploads

  const RpgStats({
    required this.perception,
    required this.stamina,
    required this.linguistics,
    required this.stealth,
    required this.integrity,
  });

  int get totalPower =>
      perception + stamina + linguistics + stealth + integrity;
}

class ExplorerAvatarProfile {
  final String seed;
  final Color primaryColor;
  final Color secondaryColor;
  final Color skinTone;
  final Color cloakColor;
  final Color auraColor;
  final int hairStyle; // 0..4
  final int eyeStyle; // 0..3
  final int accessoryTier; // 1..8 unlocked by level
  final String funnyNickname;
  final String explorerClass;
  final List<String> unlockedNicknameHistory;
  final List<RpgCharacteristic> characteristics;
  final RpgStats stats;

  const ExplorerAvatarProfile({
    required this.seed,
    required this.primaryColor,
    required this.secondaryColor,
    required this.skinTone,
    required this.cloakColor,
    required this.auraColor,
    required this.hairStyle,
    required this.eyeStyle,
    required this.accessoryTier,
    required this.funnyNickname,
    required this.explorerClass,
    required this.unlockedNicknameHistory,
    required this.characteristics,
    required this.stats,
  });

  String get gearName => switch (accessoryTier) {
        1 => 'Paper Map & Cap',
        2 => 'Scout Binoculars',
        3 => 'Brass Compass Medallion',
        4 => 'Cartographer Tricorn & Monocle',
        5 => 'Gilded Astrolabe Halo',
        6 => 'Arcane Shapefile Staff',
        7 => 'Admiral Sextant & Cape',
        _ => 'Mythic Prime-Meridian Crown',
      };
}

/// Deterministic RPG Explorer Avatar generator:
/// - Produces a unique visual character from each user's seed
/// - Evolves funny nicknames (e.g. "Vasco da Gama", "Sidewalk Magellan", etc.)
///   and RPG characteristics/gear as Explorer XP and level grow.
class ExplorerAvatarService {
  static const List<Color> _palettes = [
    Color(0xFF0F766E), // Teal
    Color(0xFF2563EB), // Cobalt
    Color(0xFFD97706), // Amber
    Color(0xFF7C3AED), // Violet
    Color(0xFFDB2777), // Magenta
    Color(0xFF059669), // Emerald
    Color(0xFFDC2626), // Crimson
    Color(0xFF0284C7), // Ocean
  ];

  static const List<Color> _accentColors = [
    Color(0xFFF59E0B),
    Color(0xFF10B981),
    Color(0xFF38BDF8),
    Color(0xFFF43F5E),
    Color(0xFFA855F7),
    Color(0xFFFB923C),
  ];

  static const List<Color> _skinTones = [
    Color(0xFFFDE0C8),
    Color(0xFFF3C6A5),
    Color(0xFFE0A77E),
    Color(0xFFC4845C),
    Color(0xFF8D5524),
    Color(0xFF6B3E26),
  ];

  /// Tiered funny explorer nicknames (index = level - 1).
  /// Each level has 3 hilarious variants picked deterministically from the user's seed.
  static const List<List<String>> _funnyNicknamesByLevel = [
    [
      'Lost in the Parking Lot',
      'Vasco da Bench',
      'Pigeon-Guided Rookie',
    ],
    [
      'Sidewalk Magellan',
      'Captain Crosswalk',
      'Marco Polo of Cafes',
    ],
    [
      'Vasco da Gama',
      'Sir Cartograph-a-Lot',
      'Lord of the Roundabouts',
    ],
    [
      'Amerigo GPS-pucci',
      'Baron of Benches',
      'The Polyglot Pathfinder',
    ],
    [
      'Ferdinand Magell-pin',
      'Archduke of Alleyways',
      'The GPS Whisperer',
    ],
    [
      'Grand Admiral Zheng He',
      'Sorcerer of Shapefiles',
      'Low-Orbit Satellite Tamer',
    ],
    [
      'Vasco da Galaxy',
      'Monarch of the Equator',
      'Mythic Atlas Architect',
    ],
    [
      'Prime Meridian Sovereign',
      'Omniscient OSM Demigod',
      'Eternal Cartomancer',
    ],
  ];

  static const List<String> _rpgClasses = [
    'Street Ranger',
    'Trail Alchemist',
    'Urban Bard',
    'Compass Paladin',
    'Satellite Rogue',
    'Atlas Wizard',
  ];

  static const List<RpgCharacteristic> _levelCharacteristics = [
    RpgCharacteristic(
      id: 'keen_pocket_map',
      name: 'Pocket Compass Sense',
      bonusText: '+10% Direction Flair',
      description: 'Never walks in circles... well, mostly never.',
      unlockedAtLevel: 1,
      icon: Icons.explore_rounded,
      color: Color(0xFF0F766E),
    ),
    RpgCharacteristic(
      id: 'eagle_sign_reader',
      name: 'Eagle-Eyed Sign Reader',
      bonusText: '+2 PER · Sharp Sight',
      description: 'Spots tiny opening_hours stickers from across the street.',
      unlockedAtLevel: 2,
      icon: Icons.visibility_rounded,
      color: Color(0xFF2563EB),
    ),
    RpgCharacteristic(
      id: 'vasco_stride',
      name: 'Vasco’s Sea-Legs',
      bonusText: '+3 STA · Trail Stride',
      description: 'Turns casual coffee walks into legendary uncharted voyages.',
      unlockedAtLevel: 3,
      icon: Icons.directions_walk_rounded,
      color: Color(0xFFD97706),
    ),
    RpgCharacteristic(
      id: 'rosetta_tongue',
      name: 'Rosetta Banter',
      bonusText: '+3 LNG · Dual-Tag Mastery',
      description: 'Effortlessly names bakeries in two scripts before breakfast.',
      unlockedAtLevel: 4,
      icon: Icons.translate_rounded,
      color: Color(0xFF7C3AED),
    ),
    RpgCharacteristic(
      id: 'duplicate_radar',
      name: 'Anti-Duplicate Sixth Sense',
      bonusText: '+3 PER · OSM Hygiene',
      description: 'Smells a pre-existing OSM node from 45 meters away.',
      unlockedAtLevel: 5,
      icon: Icons.radar_rounded,
      color: Color(0xFF059669),
    ),
    RpgCharacteristic(
      id: 'off_grid_hermit',
      name: 'Zero-Signal Immunity',
      bonusText: '+4 OFG · Offline Resilience',
      description: 'Maps deep canyons and subway tunnels without a single bar.',
      unlockedAtLevel: 6,
      icon: Icons.wifi_off_rounded,
      color: Color(0xFFEA580C),
    ),
    RpgCharacteristic(
      id: 'crypto_seal',
      name: 'Cryptographic Sealbearer',
      bonusText: '+4 TRU · Hardware Attested',
      description: 'Every field note carries an unforgeable proof of presence.',
      unlockedAtLevel: 7,
      icon: Icons.verified_user_rounded,
      color: Color(0xFF0284C7),
    ),
    RpgCharacteristic(
      id: 'mythic_cartomancer',
      name: 'Cartomancer Aura',
      bonusText: '+5 ALL · Legendary Mapper',
      description: 'Streets quietly straighten themselves whenever you walk by.',
      unlockedAtLevel: 8,
      icon: Icons.auto_awesome_rounded,
      color: Color(0xFFDB2777),
    ),
  ];

  static ExplorerAvatarProfile buildAvatar({
    required String seed,
    required int level,
    required int xp,
    required int recordsCount,
    required int multiPhotoRecordsCount,
    required int multilingualRecordsCount,
    required int offlineRecordsCount,
    required double totalTrailKm,
    required int activeDayStreak,
  }) {
    final safeSeed = seed.trim().isEmpty ? 'edge-mapper-default' : seed.trim();
    final digest = sha256.convert(utf8.encode(safeSeed)).bytes;

    final primary = _palettes[digest[0] % _palettes.length];
    final secondary = _accentColors[digest[1] % _accentColors.length];
    final skin = _skinTones[digest[2] % _skinTones.length];
    final cloak = _palettes[(digest[3] + 3) % _palettes.length];
    final aura = _accentColors[(digest[4] + 2) % _accentColors.length];
    final hairStyle = digest[5] % 5;
    final eyeStyle = digest[6] % 4;
    final explorerClass = _rpgClasses[digest[7] % _rpgClasses.length];

    final clampedLevel = level.clamp(1, _funnyNicknamesByLevel.length);
    final unlockedHistory = <String>[];
    for (var lv = 1; lv <= clampedLevel; lv++) {
      final variants = _funnyNicknamesByLevel[lv - 1];
      // Deterministic per-user pick (ensuring "Vasco da Gama" appears cleanly at Lv 3 for default/many seeds!)
      final variantIdx = lv == 3
          ? (digest[8] % 2 == 0 ? 0 : digest[8 + lv] % variants.length)
          : digest[(8 + lv) % digest.length] % variants.length;
      unlockedHistory.add(variants[variantIdx]);
    }

    final currentNickname = unlockedHistory.last;

    // Unlock RPG characteristics progressively by level + activity milestones
    final traits = <RpgCharacteristic>[
      for (final c in _levelCharacteristics)
        if (level >= c.unlockedAtLevel) c,
    ];

    // Bonus activity-driven RPG quirks
    if (multiPhotoRecordsCount >= 1) {
      traits.add(
        const RpgCharacteristic(
          id: 'multi_angle_lens',
          name: '360° Shutter Tactician',
          bonusText: '+3 PER · Multi-Photo Merge',
          description: 'Fuses multiple angles into ultra-detailed POI profiles.',
          unlockedAtLevel: 1,
          icon: Icons.collections_rounded,
          color: Color(0xFF0EA5E9),
        ),
      );
    }
    final stats = RpgStats(
      perception: (10 + level * 4 + recordsCount * 2 + multiPhotoRecordsCount * 4)
          .clamp(1, 99),
      stamina: (10 + level * 3 + (totalTrailKm * 5).round() + activeDayStreak * 3)
          .clamp(1, 99),
      linguistics: (8 + level * 3 + multilingualRecordsCount * 5).clamp(1, 99),
      stealth: (8 + level * 3 + offlineRecordsCount * 4).clamp(1, 99),
      integrity: (10 + level * 3 + recordsCount * 2).clamp(1, 99),
    );

    return ExplorerAvatarProfile(
      seed: safeSeed,
      primaryColor: primary,
      secondaryColor: secondary,
      skinTone: skin,
      cloakColor: cloak,
      auraColor: aura,
      hairStyle: hairStyle,
      eyeStyle: eyeStyle,
      accessoryTier: clampedLevel,
      funnyNickname: currentNickname,
      explorerClass: explorerClass,
      unlockedNicknameHistory: unlockedHistory,
      characteristics: traits,
      stats: stats,
    );
  }
}
