import '../data/osm_tag_catalog.dart';
import '../data/osm_tag_standards.dart';
import '../models/osm_record.dart';

class OsmPreset {
  final String label;
  final String summary;
  final Map<String, String> tags;
  final double defaultOffsetMeters;
  final bool isTrailPreset;

  const OsmPreset({
    required this.label,
    required this.summary,
    required this.tags,
    this.defaultOffsetMeters = 5.0,
    this.isTrailPreset = false,
  });
}

class OsmInferenceResult {
  final String summary;
  final String fieldNotes;
  final String detectedLanguage;
  final String osmType;
  final double estimatedOffsetMeters;
  final String distanceReasoning;
  final Map<String, String> tags;
  final List<String> detectedLabels;
  final Map<String, double> tagCandidates;
  final AiSource aiSource;
  final String diagnosticNote;

  const OsmInferenceResult({
    required this.summary,
    this.fieldNotes = '',
    required this.detectedLanguage,
    required this.osmType,
    required this.estimatedOffsetMeters,
    this.distanceReasoning = '',
    required this.tags,
    this.detectedLabels = const [],
    this.tagCandidates = const {},
    required this.aiSource,
    this.diagnosticNote = '',
  });
}

/// Fast, pure-Dart multilingual script detector, visual-scale distance estimator,
/// and OSM tag mapper used alongside on-device ML Kit Vision + OCR (100% offline).
class OsmHeuristicMapper {
  static const List<OsmPreset> quickPresets = [
    OsmPreset(
      label: 'Trailhead / Sign',
      summary: 'Hiking guidepost / trail sign',
      tags: {'tourism': 'information', 'information': 'guidepost', 'hiking': 'yes'},
      defaultOffsetMeters: 3.0,
      isTrailPreset: true,
    ),
    OsmPreset(
      label: 'Bench',
      summary: 'Public bench',
      tags: {'amenity': 'bench'},
      defaultOffsetMeters: 3.0,
      isTrailPreset: true,
    ),
    OsmPreset(
      label: 'Viewpoint',
      summary: 'Scenic viewpoint',
      tags: {'tourism': 'viewpoint'},
      defaultOffsetMeters: 5.0,
      isTrailPreset: true,
    ),
    OsmPreset(
      label: 'Water',
      summary: 'Drinking water',
      tags: {'amenity': 'drinking_water'},
      defaultOffsetMeters: 3.0,
      isTrailPreset: true,
    ),
    OsmPreset(
      label: 'Cafe',
      summary: 'Cafe / coffee shop',
      tags: {'amenity': 'cafe'},
      defaultOffsetMeters: 8.0,
    ),
    OsmPreset(
      label: 'Bakery',
      summary: 'Local bakery',
      tags: {'shop': 'bakery'},
      defaultOffsetMeters: 8.0,
    ),
    OsmPreset(
      label: 'Shop',
      summary: 'Local shop',
      tags: {'shop': 'yes'},
      defaultOffsetMeters: 8.0,
    ),
    OsmPreset(
      label: 'Convenience',
      summary: 'Convenience store',
      tags: {'shop': 'convenience'},
      defaultOffsetMeters: 9.0,
    ),
    OsmPreset(
      label: 'Park',
      summary: 'Public park',
      tags: {'leisure': 'park'},
      defaultOffsetMeters: 10.0,
      isTrailPreset: true,
    ),
    OsmPreset(
      label: 'Shrine / Temple',
      summary: 'Place of worship',
      tags: {'amenity': 'place_of_worship'},
      defaultOffsetMeters: 12.0,
    ),
    OsmPreset(
      label: 'Bus Stop',
      summary: 'Bus stop',
      tags: {'highway': 'bus_stop', 'public_transport': 'platform'},
      defaultOffsetMeters: 4.0,
    ),
    OsmPreset(
      label: 'Vending',
      summary: 'Vending machine',
      tags: {'amenity': 'vending_machine'},
      defaultOffsetMeters: 3.0,
    ),
    OsmPreset(
      label: 'Toilets',
      summary: 'Public toilets',
      tags: {'amenity': 'toilets'},
      defaultOffsetMeters: 6.0,
      isTrailPreset: true,
    ),
    OsmPreset(
      label: 'Post Box',
      summary: 'Post box',
      tags: {'amenity': 'post_box'},
      defaultOffsetMeters: 3.0,
    ),
  ];

  static final RegExp _hiraganaKatakana = RegExp(r'[\u3040-\u30FF]');
  static final RegExp _hangul = RegExp(r'[\uAC00-\uD7AF\u1100-\u11FF]');
  static final RegExp _cjkHan = RegExp(r'[\u4E00-\u9FFF]');
  static final RegExp _cyrillic = RegExp(r'[\u0400-\u04FF]');
  static final RegExp _arabic = RegExp(r'[\u0600-\u06FF]');
  static final RegExp _latinLetters = RegExp(r'[A-Za-zÀ-ÿ]');

  /// Detects primary ISO 639-1 language code from OCR text.
  static String detectPrimaryLanguage(String text) {
    if (text.trim().isEmpty) return 'en';
    if (_hiraganaKatakana.hasMatch(text)) return 'ja';
    if (_hangul.hasMatch(text)) return 'ko';
    if (_cjkHan.hasMatch(text)) {
      if (text.contains('丁目') ||
          text.contains('駅前') ||
          text.contains('神社') ||
          text.contains('登山口') ||
          text.contains('郵便')) {
        return 'ja';
      }
      return 'zh';
    }
    if (_cyrillic.hasMatch(text)) return 'ru';
    if (_arabic.hasMatch(text)) return 'ar';

    final lower = text.toLowerCase();
    if (RegExp(r'[éèêëàâçùûôœ]').hasMatch(lower) ||
        lower.contains('boulangerie') ||
        lower.contains('pharmacie') ||
        lower.contains('rue ')) {
      return 'fr';
    }
    if (RegExp(r'[äöüß]').hasMatch(lower) ||
        lower.contains('straße') ||
        lower.contains('apotheke') ||
        lower.contains('bäckerei')) {
      return 'de';
    }
    if (RegExp(r'[ñ¿¡]').hasMatch(lower) ||
        lower.contains('calle ') ||
        lower.contains('farmacia')) {
      return 'es';
    }
    return 'en';
  }

  /// Extracts primary local name and dual-language tags (`name`, `name:<mainLang>`,
  /// and `name:<secondaryLang>`):
  /// - The user's Main Language ([primaryLanguage] / first of [confidentLanguages])
  ///   is always prioritized as the main user language.
  /// - [preferredFallbackLanguage] is strictly used as the SECONDARY language for OSM tags.
  /// - When English is the only available name (e.g., English-only signage), English
  ///   (`name` / `name:en`) is preserved cleanly without inventing fake translations.
  static Map<String, String> extractMultilingualNameTags(
    List<String> ocrLines,
    String primaryLang, {
    String? countryLanguage,
    String? primaryLanguage,
    List<String> confidentLanguages = const ['en'],
    String preferredFallbackLanguage = 'en',
  }) {
    final cleaned = ocrLines
        .map((line) => line.trim())
        .where((line) => line.length >= 2 && line.length <= 60)
        .where((line) => !RegExp(r'^[\d\s\-:./]+$').hasMatch(line))
        .toList();

    if (cleaned.isEmpty) return {};

    final localLang = primaryLang.trim().toLowerCase();
    final countryLang =
        (countryLanguage != null && countryLanguage.isNotEmpty)
            ? countryLanguage.trim().toLowerCase()
            : localLang;

    final userMainLang = (primaryLanguage != null && primaryLanguage.trim().isNotEmpty)
        ? primaryLanguage.trim().toLowerCase()
        : (confidentLanguages.isNotEmpty
            ? confidentLanguages.first.trim().toLowerCase()
            : 'en');
    final userSecondaryLang = preferredFallbackLanguage.trim().toLowerCase();

    // Primary companion language prioritizes the user's MAIN language first;
    // the fallback language is strictly secondary.
    final String? primaryCompanionLang =
        userMainLang != localLang ? userMainLang : null;
    final String? secondaryCompanionLang = (userSecondaryLang != localLang &&
            userSecondaryLang != primaryCompanionLang)
        ? userSecondaryLang
        : null;

    final tags = <String, String>{};

    // Separate native-script lines vs Latin lines for bilingual signage
    String? nativeName;
    String? latinName;

    for (final line in cleaned) {
      final hasNonLatin = _hiraganaKatakana.hasMatch(line) ||
          _cjkHan.hasMatch(line) ||
          _hangul.hasMatch(line) ||
          _cyrillic.hasMatch(line) ||
          _arabic.hasMatch(line);

      if (hasNonLatin && nativeName == null) {
        nativeName = line;
      } else if (!hasNonLatin && _latinLetters.hasMatch(line) && latinName == null) {
        latinName = line;
      }
    }

    final primary = nativeName ?? cleaned.first;
    tags['name'] = primary;
    tags['name:$localLang'] = primary;

    if (countryLang != localLang && nativeName != null) {
      tags['name:$countryLang'] = nativeName;
    }

    // Add companion tag(s) when bilingual signage contains a distinct Latin/secondary name
    if (latinName != null && latinName != primary) {
      final latinDetected = detectPrimaryLanguage(latinName);
      if (latinDetected == userMainLang && userMainLang != localLang) {
        tags['name:$userMainLang'] = latinName;
      } else if (latinDetected == userSecondaryLang &&
          userSecondaryLang != localLang) {
        tags['name:$userSecondaryLang'] = latinName;
        if (latinDetected == 'en') {
          tags['name:en'] = latinName;
        }
      } else if (latinDetected == 'en') {
        // English is the only Latin name on the sign: keep name:en cleanly,
        // and also populate user's main/secondary tag if they match the fallback setup.
        tags['name:en'] = latinName;
        if (primaryCompanionLang != null &&
            primaryCompanionLang == userSecondaryLang) {
          tags['name:$primaryCompanionLang'] = latinName;
        }
      } else {
        final target = primaryCompanionLang ?? secondaryCompanionLang ?? 'en';
        tags['name:$target'] = latinName;
      }
    } else if (localLang == 'en') {
      // English-only signage: keep English as name & name:en cleanly!
      tags['name:en'] = primary;
    }

    return tags;
  }

  /// Estimates distance in meters from camera to the photographed object/shop
  /// using visual scale cues (OCR sign bounding box height relative to frame height)
  /// combined with category-specific physical priors (street width, facade size, etc.).
  static (double, String) estimateDistanceMeters({
    required double baseDistanceMeters,
    double? maxOcrHeightRatio, // max text line height / image height (0..1)
    List<String> imageLabels = const [],
    bool isOnTrail = false,
  }) {
    final lowerLabels = imageLabels.map((l) => l.toLowerCase()).toList();
    double distance = baseDistanceMeters;
    final cues = <String>[];

    // 1. Visual sign text scale cue (pinhole camera approximation:
    //    typical shop/street sign letter height ~0.18m..0.35m, phone FOV ~65° vertical)
    if (maxOcrHeightRatio != null && maxOcrHeightRatio > 0.004) {
      // Larger text ratio -> much closer to camera; tiny text -> far across street
      if (maxOcrHeightRatio >= 0.12) {
        distance = (distance * 0.45).clamp(1.5, 5.0);
        cues.add('large close-up sign text');
      } else if (maxOcrHeightRatio >= 0.06) {
        distance = (distance * 0.72).clamp(2.5, 9.0);
        cues.add('medium-close signage scale');
      } else if (maxOcrHeightRatio >= 0.025) {
        distance = (distance * 1.15).clamp(5.0, 18.0);
        cues.add('mid-distance storefront/sign scale');
      } else {
        distance = (distance * 1.85).clamp(10.0, 35.0);
        cues.add('small distant signage across street');
      }
    }

    // 2. Scene context cues from ML Kit image labels
    if (lowerLabels.any((l) => l.contains('road') || l.contains('street') || l.contains('asphalt') || l.contains('car') || l.contains('vehicle'))) {
      distance += 4.5;
      cues.add('street/road foreground detected');
    }
    if (lowerLabels.any((l) => l.contains('sky') || l.contains('mountain') || l.contains('horizon') || l.contains('landscape'))) {
      distance += isOnTrail ? 6.0 : 5.0;
      cues.add('wide open/distant view');
    }
    if (lowerLabels.any((l) => l.contains('building') || l.contains('facade') || l.contains('architecture') || l.contains('house'))) {
      distance = distance < 7.0 ? 8.5 : distance + 2.0;
      cues.add('building facade scale');
    }

    final rounded = (distance.clamp(1.5, 80.0) * 2).round() / 2.0;
    final reason = cues.isNotEmpty
        ? 'Visual estimate (~${rounded.toStringAsFixed(1)}m): ${cues.join(', ')}'
        : 'Category baseline estimate (~${rounded.toStringAsFixed(1)}m)';
    return (rounded, reason);
  }

  /// Infers structured OSM tags, distance, and ranked tag candidates from offline
  /// ML Kit labels, OCR lines, text bounding-box scale, compass heading, and user settings.
  static OsmInferenceResult inferFromOnDeviceSignals({
    required List<String> imageLabels,
    required List<String> ocrLines,
    double? headingDegrees,
    double? maxOcrHeightRatio,
    String? userHint,
    OsmPreset? preset,
    bool isOnTrail = false,
    String? countryLanguage,
    String? primaryLanguage,
    List<String> confidentLanguages = const ['en'],
    String preferredFallbackLanguage = 'en',
    bool hasGpsFix = true,
  }) {
    final combinedText = [
      if (userHint != null) userHint,
      ...ocrLines,
    ].join('\n');

    final detectedScriptLang = detectPrimaryLanguage(combinedText);
    final primaryLang =
        combinedText.trim().isEmpty && countryLanguage != null && countryLanguage.isNotEmpty
            ? countryLanguage
            : detectedScriptLang;

    final tags = <String, String>{};
    String summary = preset?.summary ?? 'Field OSM draft';
    double baseOffset = preset?.defaultOffsetMeters ?? 6.0;

    if (preset != null) {
      tags.addAll(preset.tags);
    }

    // Add dual-language name tags from OCR text
    tags.addAll(
      extractMultilingualNameTags(
        ocrLines,
        primaryLang,
        countryLanguage: countryLanguage,
        primaryLanguage: primaryLanguage,
        confidentLanguages: confidentLanguages,
        preferredFallbackLanguage: preferredFallbackLanguage,
      ),
    );

    final haystack = [
      combinedText.toLowerCase(),
      ...imageLabels.map((l) => l.toLowerCase()),
    ].join(' ');

    if (preset == null) {
      final matched = _matchCategory(haystack, isOnTrail: isOnTrail);
      tags.addAll(matched.tags);
      summary = matched.summary;
      baseOffset = matched.offsetMeters;
    }

    // Visual distance refinement
    final (estimatedDistance, distanceReason) = estimateDistanceMeters(
      baseDistanceMeters: baseOffset,
      maxOcrHeightRatio: maxOcrHeightRatio,
      imageLabels: imageLabels,
      isOnTrail: isOnTrail,
    );

    // Record OSM directional tag ONLY for directional features (viewpoint, guidepost, bench).
    // Note: camera:direction is NOT a standard POI tag on OSM (compass heading is stored on the record).
    if (headingDegrees != null) {
      final rounded = headingDegrees.round() % 360;
      if (tags['tourism'] == 'viewpoint' ||
          tags['information'] == 'guidepost' ||
          tags['amenity'] == 'bench') {
        tags['direction'] = '$rounded';
      }
    }

    tags['source'] = OsmTagStandards.recommendedSource(hasGpsFix: hasGpsFix);
    if (imageLabels.isNotEmpty) {
      tags['fixme'] =
          'Verify offline draft (labels: ${imageLabels.take(4).join(", ")})';
    }

    final cleanTags = OsmTagStandards.modernizeTags(
      tags,
      hasGpsFix: hasGpsFix,
      stripLocalOnly: true,
    );

    // Build ranked probability candidates for the OSM Tag Selector
    final candidates = <String, double>{};
    for (final entry in OsmTagCatalog.entries) {
      double score = 0.0;
      for (final kw in entry.keywords) {
        if (kw.length >= 2 && haystack.contains(kw.toLowerCase())) {
          score += 0.34;
        }
      }
      if (cleanTags[entry.key] == entry.value && entry.value.isNotEmpty) {
        score = score < 0.85 ? 0.85 : score;
      }
      if (score >= 0.30) {
        candidates[entry.tagString] = score.clamp(0.30, 0.96);
      }
    }

    final diagParts = <String>[
      if (imageLabels.isNotEmpty) 'Labels: ${imageLabels.take(5).join(", ")}',
      if (ocrLines.isNotEmpty) 'OCR: ${ocrLines.take(3).join(" / ")}',
    ];

    return OsmInferenceResult(
      summary: cleanTags['name'] != null ? '$summary — ${cleanTags['name']}' : summary,
      detectedLanguage: primaryLang,
      osmType: 'node',
      estimatedOffsetMeters: estimatedDistance,
      distanceReasoning: distanceReason,
      tags: cleanTags,
      detectedLabels: List<String>.from(imageLabels),
      tagCandidates: candidates,
      aiSource: preset != null && imageLabels.isEmpty && ocrLines.isEmpty
          ? AiSource.manual
          : AiSource.mlKitOffline,
      diagnosticNote: diagParts.join(' | '),
    );
  }

  static _CategoryMatch _matchCategory(String haystack, {required bool isOnTrail}) {
    bool hasAny(List<String> terms) => terms.any(haystack.contains);

    if (hasAny(['神社', 'shrine', 'torii', '鳥居'])) {
      return const _CategoryMatch(
        summary: 'Shinto shrine',
        tags: {'amenity': 'place_of_worship', 'religion': 'shinto'},
        offsetMeters: 12.0,
      );
    }
    if (hasAny(['寺', 'temple', 'buddhist'])) {
      return const _CategoryMatch(
        summary: 'Buddhist temple',
        tags: {'amenity': 'place_of_worship', 'religion': 'buddhist'},
        offsetMeters: 12.0,
      );
    }
    if (hasAny(['church', 'cathedral', 'église', 'kirche'])) {
      return const _CategoryMatch(
        summary: 'Church',
        tags: {'amenity': 'place_of_worship', 'religion': 'christian'},
        offsetMeters: 14.0,
      );
    }
    if (hasAny(['bakery', 'boulangerie', 'パン', 'bäckerei', 'patisserie'])) {
      return const _CategoryMatch(
        summary: 'Bakery',
        tags: {'shop': 'bakery'},
        offsetMeters: 8.0,
      );
    }
    if (hasAny(['cafe', 'coffee', 'カフェ', '珈琲', '喫茶'])) {
      return const _CategoryMatch(
        summary: 'Cafe / Coffee shop',
        tags: {'amenity': 'cafe'},
        offsetMeters: 8.0,
      );
    }
    if (hasAny(['restaurant', 'ramen', 'ラーメン', '食堂', '居酒屋', 'izakaya', 'bistro', 'sushi', 'food'])) {
      return const _CategoryMatch(
        summary: 'Restaurant',
        tags: {'amenity': 'restaurant'},
        offsetMeters: 9.0,
      );
    }
    if (hasAny(['7-eleven', 'lawson', 'familymart', 'コンビニ', 'convenience', 'mart'])) {
      return const _CategoryMatch(
        summary: 'Convenience store',
        tags: {'shop': 'convenience'},
        offsetMeters: 9.0,
      );
    }
    if (hasAny(['pharmacy', 'drug', '薬局', 'pharmacie', 'apotheke'])) {
      return const _CategoryMatch(
        summary: 'Pharmacy',
        tags: {'amenity': 'pharmacy'},
        offsetMeters: 8.0,
      );
    }
    if (hasAny(['bus', 'バス', 'stop', 'station', '駅'])) {
      return const _CategoryMatch(
        summary: 'Transit / Bus stop',
        tags: {'highway': 'bus_stop', 'public_transport': 'platform'},
        offsetMeters: 4.5,
      );
    }
    if (hasAny(['post', '郵便', 'mail'])) {
      return const _CategoryMatch(
        summary: 'Post box / Post office',
        tags: {'amenity': 'post_box'},
        offsetMeters: 3.0,
      );
    }
    if (hasAny(['vending', '自販機', 'drink'])) {
      return const _CategoryMatch(
        summary: 'Vending machine',
        tags: {'amenity': 'vending_machine'},
        offsetMeters: 3.0,
      );
    }
    if (hasAny(['toilet', 'wc', 'restroom', 'トイレ'])) {
      return const _CategoryMatch(
        summary: 'Public toilets',
        tags: {'amenity': 'toilets'},
        offsetMeters: 6.0,
      );
    }
    if (hasAny(['bench', 'ベンチ', 'seat'])) {
      return const _CategoryMatch(
        summary: 'Bench',
        tags: {'amenity': 'bench'},
        offsetMeters: 3.0,
      );
    }
    if (hasAny(['登山', 'trail', 'guidepost', 'hiking', 'sign', 'signage', '看板', '案内'])) {
      return const _CategoryMatch(
        summary: 'Trail / Street guidepost',
        tags: {'tourism': 'information', 'information': 'guidepost'},
        offsetMeters: 4.0,
      );
    }
    if (hasAny(['mountain', 'peak', 'forest', 'valley', 'cliff', 'waterfall', 'panorama', '展望'])) {
      return const _CategoryMatch(
        summary: 'Scenic viewpoint / natural feature',
        tags: {'tourism': 'viewpoint'},
        offsetMeters: 6.0,
      );
    }
    if (hasAny(['park', 'garden', '公園', 'tree', 'plant'])) {
      return _CategoryMatch(
        summary: isOnTrail ? 'Trail waypoint' : 'Park / green area',
        tags: isOnTrail
            ? {'highway': 'path', 'tourism': 'information'}
            : {'leisure': 'park'},
        offsetMeters: 8.0,
      );
    }
    if (hasAny(['bridge', '橋'])) {
      return const _CategoryMatch(
        summary: 'Bridge',
        tags: {'man_made': 'bridge'},
        offsetMeters: 8.0,
      );
    }
    if (hasAny(['store', 'shop', 'retail', 'boutique', 'building', 'facade', 'house'])) {
      return const _CategoryMatch(
        summary: 'Street shop / building',
        tags: {'building': 'yes'},
        offsetMeters: 10.0,
      );
    }

    return _CategoryMatch(
      summary: isOnTrail ? 'Trail feature' : 'Street feature',
      tags: isOnTrail
          ? {'tourism': 'information', 'hiking': 'yes'}
          : {'note': 'Needs OSM category tag'},
      offsetMeters: 6.0,
    );
  }
}

class _CategoryMatch {
  final String summary;
  final Map<String, String> tags;
  final double offsetMeters;

  const _CategoryMatch({
    required this.summary,
    required this.tags,
    required this.offsetMeters,
  });
}
