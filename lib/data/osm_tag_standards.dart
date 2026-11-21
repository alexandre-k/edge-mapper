import 'osm_tag_catalog.dart';

/// OpenStreetMap tag standards, deprecation guard, real-OSM key registry,
/// automatic tag modernization, publishability classification, and OSM Wiki
/// documentation links.
///
/// Ensures Edge Mapper follows current OpenStreetMap Wiki tagging guidelines:
/// - Automatically avoids/migrates deprecated tags (e.g., `day_off` -> `opening_hours`
///   with days before hours, `amenity=gym` -> `leisure=fitness_centre`, etc.).
/// - Distinguishes publishable OSM tags from local-only capture metadata
///   (e.g., `camera:direction` on non-camera POIs, `created_by` on elements).
/// - Standardizes `source` to `survey` (avoiding non-standard `GPS` and
///   software/app names).
/// - Generates exact OSM Wiki URLs so mappers can verify any tag's status.
class DeprecatedTagNotice {
  final String key;
  final String value;
  final String reason;
  final String replacementSummary;
  final bool canAutoFix;
  final String wikiUrl;
  final bool isInvalidTag;

  const DeprecatedTagNotice({
    required this.key,
    required this.value,
    required this.reason,
    required this.replacementSummary,
    required this.canAutoFix,
    required this.wikiUrl,
    this.isInvalidTag = false,
  });
}

class OsmTagStandards {
  OsmTagStandards._();

  static const String osmWikiBaseUrl = 'https://wiki.openstreetmap.org/wiki';
  static const String openingHoursWikiUrl = '$osmWikiBaseUrl/Key:opening_hours';
  static const String deprecatedFeaturesWikiUrl =
      '$osmWikiBaseUrl/Deprecated_features';

  static const List<String> _osmWeekdays = [
    'Mo',
    'Tu',
    'We',
    'Th',
    'Fr',
    'Sa',
    'Su',
  ];

  /// Primary feature keys that have dedicated `Tag:key=value` OSM Wiki pages.
  static const Set<String> _primaryFeatureKeys = {
    'amenity',
    'shop',
    'tourism',
    'highway',
    'leisure',
    'fitness_station',
    'playground',
    'natural',
    'historic',
    'information',
    'building',
    'man_made',
    'barrier',
    'surface',
    'railway',
    'public_transport',
    'office',
    'emergency',
    'craft',
    'healthcare',
    'landuse',
    'sport',
    'waterway',
    'power',
    'place',
  };

  /// True when [key] is a primary OSM feature key whose value comes from a
  /// documented OpenStreetMap vocabulary (eligible for `key=value` verification).
  static bool isPrimaryFeatureKey(String key) =>
      _primaryFeatureKeys.contains(key.trim().toLowerCase());

  /// Documented OpenStreetMap `fitness_station=*` values (wiki.openstreetmap.org/wiki/Key:fitness_station).
  static const Set<String> _validFitnessStationValues = {
    'horizontal_ladder',
    'horizontal_bar',
    'parallel_bars',
    'sit-up',
    'push-up',
    'balance_beam',
    'stairs',
    'box',
    'rings',
    'climbing_wall',
    'climbing_frame',
    'elliptical',
    'bicycle',
    'rowing',
    'stretching',
    'hyperextension',
    'leg_press',
    'chest_press',
    'pull_down',
    'dip',
    'twister',
    'walker',
    'sign',
    'bars',
    'multi-gym',
    'slalom',
    'rope',
    'pole',
    'bench',
    'ski',
    'stepper',
    'push_up',
    'sit_up',
  };

  /// Maps common LLM/colloquial equipment labels to official OSM Wiki `fitness_station=*` values.
  static const Map<String, String> _fitnessStationValueAliases = {
    'monkey_bars': 'horizontal_ladder',
    'monkey_bar': 'horizontal_ladder',
    'overhead_ladder': 'horizontal_ladder',
    'horizontal_ladders': 'horizontal_ladder',
    'pull_up': 'horizontal_bar',
    'pull-up': 'horizontal_bar',
    'pull_up_bar': 'horizontal_bar',
    'pull_up_bars': 'horizontal_bar',
    'pullup': 'horizontal_bar',
    'pullup_bar': 'horizontal_bar',
    'pullup_bars': 'horizontal_bar',
    'chin_up': 'horizontal_bar',
    'chin_up_bar': 'horizontal_bar',
    'chin-up': 'horizontal_bar',
    'high_bar': 'horizontal_bar',
    'horizontal_bars': 'horizontal_bar',
    'dip_bars': 'parallel_bars',
    'dip_bar': 'parallel_bars',
    'situp': 'sit-up',
    'sit_up': 'sit-up',
    'sit_up_bench': 'sit-up',
    'sit-up_bench': 'sit-up',
    'pushup': 'push-up',
    'push_up': 'push-up',
    'push_up_bars': 'push-up',
    'exercise_bike': 'bicycle',
    'stationary_bike': 'bicycle',
    'cross_trainer': 'elliptical',
    'rower': 'rowing',
    'rowing_machine': 'rowing',
    'stretch': 'stretching',
    'box_jump': 'box',
    'step_up': 'stairs',
    'gymnastic_rings': 'rings',
  };

  /// Documented OpenStreetMap `playground=*` equipment values (wiki.openstreetmap.org/wiki/Key:playground).
  static const Set<String> _validPlaygroundValues = {
    'monkey_bars',
    'horizontal_bar',
    'climbingframe',
    'slide',
    'swing',
    'seesaw',
    'springy',
    'sandpit',
    'roundabout',
    'zipwire',
    'balancebeam',
    'trampoline',
    'structure',
    'playhouse',
    'basketswing',
    'climbingwall',
    'cushion',
    'hopscotch',
    'map',
    'splash_pad',
    'water',
    'youth_bench',
    'activitypanel',
    'digging_box',
    'cableway',
    'sledding',
    'teenshelter',
    'bowls',
    'carousel',
    'tunnel_tube',
    'amphitheatre',
    'music',
    'water_table',
  };

  static const Map<String, String> _playgroundValueAliases = {
    'monkey_bar': 'monkey_bars',
    'horizontal_ladder': 'monkey_bars',
    'climbing_frame': 'climbingframe',
    'jungle_gym': 'climbingframe',
    'balance_beam': 'balancebeam',
    'climbing_wall': 'climbingwall',
    'zip_line': 'zipwire',
    'zipline': 'zipwire',
    'merry_go_round': 'roundabout',
    'sandbox': 'sandpit',
    'basket_swing': 'basketswing',
    'pull_up_bar': 'horizontal_bar',
    'pull_up_bars': 'horizontal_bar',
    'horizontal_bars': 'horizontal_bar',
    'teeter_totter': 'seesaw',
  };

  /// Non-existent LLM-hallucinated keys that describe fitness station equipment.
  static const Set<String> _hallucinatedFitnessKeys = {
    'fitness_equipment',
    'workout_equipment',
    'exercise_equipment',
    'fitness_type',
    'exercise_type',
    'calisthenics_equipment',
  };

  /// Non-existent LLM-hallucinated keys that describe playground equipment.
  static const Set<String> _hallucinatedPlaygroundKeys = {
    'playground_equipment',
    'play_equipment',
    'playground_type',
  };

  /// Authoritative allowlist of documented OpenStreetMap Wiki keys so AI output
  /// cannot invent non-existent keys like `fitness_equipment=*`.
  static const Set<String> _documentedOsmKeys = {
    // Primary feature keys
    'amenity', 'shop', 'tourism', 'leisure', 'highway', 'natural', 'historic',
    'man_made', 'building', 'barrier', 'landuse', 'waterway', 'railway',
    'public_transport', 'office', 'craft', 'healthcare', 'emergency', 'power',
    'sport', 'place', 'aeroway', 'club', 'diplomatic', 'government',
    'industrial', 'military', 'telecom', 'utility', 'pipeline', 'advertising',
    'boundary', 'route', 'geological', 'seamark', 'indoor', 'playground',
    'fitness_station', 'information', 'entrance', 'exit', 'door', 'kerb',
    'crossing', 'traffic_calming', 'traffic_sign', 'ford', 'bridge', 'tunnel',
    'golf', 'water', 'wetland', 'ruins', 'memorial', 'artwork_type',
    'castle_type', 'heritage', 'cemetery', 'grave', 'shelter_type',
    'bench', 'bin', 'toilets', 'drinking_water', 'shower', 'changing_table',
    'vending', 'recycling_type', 'parking', 'bicycle_parking', 'charging_station',
    // Naming & identity
    'name', 'short_name', 'alt_name', 'official_name', 'old_name', 'int_name',
    'loc_name', 'nat_name', 'reg_name', 'sorting_name', 'noname', 'unsigned_name',
    'brand', 'operator', 'network', 'ref', 'local_ref', 'official_ref',
    'owner', 'architect', 'artist_name', 'inscription', 'subject',
    'wikidata', 'wikipedia', 'wikimedia_commons', 'mapillary', 'panoramax',
    'image', 'website', 'phone', 'mobile', 'fax', 'email', 'menu',
    // Opening hours, access, fees & rules
    'opening_hours', 'collection_times', 'service_times', 'check_in', 'check_out',
    'access', 'foot', 'bicycle', 'horse', 'dog', 'dogs', 'motor_vehicle',
    'vehicle', 'motorcar', 'motorcycle', 'hgv', 'bus', 'taxi', 'psv', 'ski',
    'fee', 'charge', 'toll', 'membership', 'reservation', 'supervised',
    'lifeguard', 'self_service', 'automated', 'unattended', 'seasonal',
    'intermittent', 'lit', 'covered', 'indoor_seating', 'outdoor_seating',
    'smoking', 'air_conditioning', 'heating', 'internet_access', 'takeaway',
    'delivery', 'drive_through', 'drive_in', 'microbrewery', 'organic',
    'fair_trade', 'second_hand', 'bulk_purchase', 'zero_waste', 'halal',
    'kosher', 'vegan', 'vegetarian', 'gluten_free', 'bar', 'cafe', 'restaurant',
    // Accessibility & mobility
    'wheelchair', 'tactile_paving', 'handrail', 'ramp', 'step_count',
    'automatic_door', 'stroller', 'baby', 'breastfeeding', 'nudism',
    'blind', 'deaf', 'hearing_loop', 'min_age', 'max_age', 'female', 'male',
    'unisex', 'gender_segregated',
    // Physical geometry, materials & appearance
    'ele', 'height', 'width', 'length', 'depth', 'diameter', 'circumference',
    'levels', 'level', 'layer', 'incline', 'direction', 'orientation',
    'material', 'colour', 'surface', 'smoothness', 'tracktype', 'sac_scale',
    'trail_visibility', 'mtb:scale', 'lanes', 'oneway', 'maxspeed',
    'maxheight', 'maxwidth', 'maxweight', 'maxlength', 'sidewalk', 'cycleway',
    'footway', 'busway', 'shoulder', 'overtaking', 'passing_places',
    'capacity', 'seats', 'rooms', 'beds', 'stars', 'backrest', 'armrest',
    'shape', 'roof', 'wall', 'fence_type', 'bollard', 'gate', 'stile',
    'kissing_gate', 'cattle_grid', 'turnstile', 'lockable',
    // Food, retail, services & religion
    'cuisine', 'dish', 'brewery', 'roastery', 'coffee', 'tea', 'bakery',
    'clothes', 'shoes', 'books', 'electronics', 'furniture', 'repair',
    'rental', 'washing', 'dry_cleaning', 'self_checkout', 'cash_withdrawal',
    'atm', 'currency', 'religion', 'denomination', 'worship', 'diocese',
    // Nature, agriculture & utilities
    'leaf_type', 'leaf_cycle', 'species', 'genus', 'taxon', 'denotation',
    'trees', 'crop', 'produce', 'orchard', 'meadow', 'grassland', 'heath',
    'scrub', 'wood', 'sand', 'beach', 'rock', 'stone', 'cliff', 'peak',
    'saddle', 'ridge', 'spring', 'waterfall', 'glacier', 'volcano',
    'water_source', 'pump', 'bottle', 'fountain', 'substance', 'content',
    'voltage', 'frequency', 'cables', 'circuits', 'substation', 'plant',
    'generator', 'location', 'manhole', 'protect_class',
    'protected_area', 'protection_title',
    // Transit & signage
    'tram', 'train', 'subway', 'light_rail', 'monorail', 'ferry', 'trolleybus',
    'shelter', 'departures_board', 'passenger_information_display', 'route_ref',
    'public_transport:version', 'uic_ref', 'iata', 'icao', 'gauge', 'electrified',
    'board_type', 'map_type', 'map_size', 'guidepost', 'hiking', 'nordic_walking',
    'running', 'fitness_trail', 'trailblazed', 'osmc:symbol',
    // Camera / surveillance (only real when feature is camera/surveillance)
    'surveillance', 'camera:direction', 'camera:type', 'camera:mount',
    // Metadata & dates
    'start_date', 'end_date', 'source', 'survey:date', 'check_date', 'note',
    'description', 'fixme', 'FIXME', 'todo', 'url', 'social_facility',
    'post_box:type', 'tower:type', 'memorial:type', 'statue', 'sculpture',
  };

  /// Valid documented OSM `addr:*` subkeys.
  static const Set<String> _validAddrSubkeys = {
    'housenumber', 'housename', 'street', 'place', 'city', 'postcode',
    'country', 'state', 'province', 'district', 'subdistrict', 'suburb',
    'quarter', 'neighbourhood', 'block_number', 'unit', 'floor', 'flats',
    'hamlet', 'village', 'town', 'county', 'full', 'conscriptionnumber',
    'streetnumber', 'door', 'room', 'interpolation', 'inclusion', 'milestone',
    'postbox', 'erf',
  };

  /// Valid documented OSM colon-namespaced key prefixes.
  static const Set<String> _documentedOsmKeyPrefixes = {
    'payment:',
    'currency:',
    'contact:',
    'diet:',
    'recycling:',
    'socket:',
    'opening_hours:',
    'check_date:',
    'source:',
    'roof:',
    'building:',
    'fire_hydrant:',
    'surveillance:',
    'camera:',
    'crossing:',
    'sidewalk:',
    'cycleway:',
    'parking:',
    'toilets:',
    'wheelchair:',
    'internet_access:',
    'fuel:',
    'piste:',
    'climbing:',
    'seamark:',
    'generator:',
    'plant:',
    'healthcare:',
    'social_facility:',
    'school:',
    'religion:',
    'service:',
    'repair:',
    'rental:',
    'second_hand:',
    'dog:',
    'capacity:',
    'fee:',
    'access:',
    'playground:',
    'fitness_station:',
    'vending:',
    'artwork:',
    'memorial:',
    'tower:',
    'brand:',
    'operator:',
    'network:',
    'gtfs:',
    'mtb:',
    'osmc:',
    'post_box:',
    'advertising:',
    'heritage:',
    'ref:',
    'level:',
    'ramp:',
    'tactile_paving:',
    'kerb:',
    'destination:',
    'turn:',
    'lanes:',
    'maxspeed:',
    'hgv:',
    'bicycle:',
    'foot:',
    'motor_vehicle:',
    'change:',
    'water:',
    'species:',
    'genus:',
    'taxon:',
    'wikipedia:',
    'wikidata:',
    'wikimedia_commons:',
    'panoramax:',
    'mapillary:',
    'drink:',
    'sells:',
    'clothes:',
    'shoes:',
    'books:',
    'cuisine:',
    'stroller:',
    'changing_table:',
    'shower:',
    'drinking_water:',
    'outdoor_seating:',
    'indoor_seating:',
    'smoking:',
    'takeaway:',
    'delivery:',
    'drive_through:',
    'reservation:',
    'organic:',
    'seasonal:',
    'lit:',
    'covered:',
    'surface:',
    'smoothness:',
    'width:',
    'height:',
    'ele:',
    'direction:',
    'inscription:',
    'subject:',
  };

  static const Set<String> _languageNamespacedPrefixes = {
    'name:',
    'alt_name:',
    'short_name:',
    'official_name:',
    'old_name:',
    'int_name:',
    'loc_name:',
    'nat_name:',
    'reg_name:',
    'sorting_name:',
    'description:',
    'brand:',
    'operator:',
    'note:',
    'inscription:',
    'wikipedia:',
  };

  static final RegExp _validOsmKeySyntax =
      RegExp(r'^[a-zA-Z][a-zA-Z0-9_:-]{0,127}$');
  static final RegExp _validLangCode =
      RegExp(r'^[a-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})*$');
  static final RegExp _validSubkeyToken = RegExp(r'^[a-z0-9][a-z0-9_:-]{0,60}$');

  /// Normalizes a fitness equipment value to a documented OSM Wiki
  /// `fitness_station=*` value, or returns `null` if it is not a recognized value.
  static String? normalizeFitnessStationValue(String raw) {
    final normalized = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s]+'), '_');
    if (normalized.isEmpty) return null;
    final aliased = _fitnessStationValueAliases[normalized] ?? normalized;
    if (_validFitnessStationValues.contains(aliased)) return aliased;
    return null;
  }

  /// Normalizes a playground equipment value to a documented OSM Wiki
  /// `playground=*` value, or returns `null` if it is not a recognized value.
  static String? normalizePlaygroundValue(String raw) {
    final normalized = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s]+'), '_');
    if (normalized.isEmpty) return null;
    final aliased = _playgroundValueAliases[normalized] ?? normalized;
    if (_validPlaygroundValues.contains(aliased)) return aliased;
    return null;
  }

  /// Returns true when [key] is a documented, valid OpenStreetMap tag key
  /// (either in the curated OSM Wiki registry, in [OsmTagCatalog.knownKeys],
  /// or using a documented OSM namespace prefix with valid syntax).
  static bool isKnownOsmKey(String key) {
    final clean = key.trim();
    if (clean.isEmpty || !_validOsmKeySyntax.hasMatch(clean)) return false;
    final lower = clean.toLowerCase();

    if (_documentedOsmKeys.contains(lower) ||
        OsmTagCatalog.knownKeys.contains(lower)) {
      return true;
    }

    // Valid language-suffixed keys (name:en, name:ja, name:zh-Hant, etc.)
    for (final prefix in _languageNamespacedPrefixes) {
      if (lower.startsWith(prefix)) {
        final suffix = clean.substring(prefix.length);
        if (_validLangCode.hasMatch(suffix)) return true;
      }
    }

    // Valid addr:* keys
    if (lower.startsWith('addr:')) {
      final sub = lower.substring('addr:'.length);
      return _validAddrSubkeys.contains(sub);
    }

    // Valid documented namespace prefixes (payment:*, diet:*, recycling:*, socket:*, etc.)
    for (final prefix in _documentedOsmKeyPrefixes) {
      if (lower.startsWith(prefix)) {
        final sub = clean.substring(prefix.length);
        if (sub.isEmpty) return false;
        if (prefix == 'currency:') {
          return RegExp(r'^[A-Z]{3}$').hasMatch(sub) ||
              RegExp(r'^[a-z]{3}$').hasMatch(sub);
        }
        return _validSubkeyToken.hasMatch(sub.toLowerCase());
      }
    }

    return false;
  }

  /// Controlled-vocabulary secondary OSM keys whose values come from a
  /// documented OpenStreetMap vocabulary (checked offline & via live Taginfo).
  static const Set<String> _controlledSecondaryKeys = {
    'source',
    'access',
    'wheelchair',
    'internet_access',
    'smoking',
    'fee',
    'lit',
    'parking',
    'bicycle_parking',
    'smoothness',
    'tracktype',
    'sac_scale',
    'trail_visibility',
    'leaf_type',
    'leaf_cycle',
    'oneway',
    'tactile_paving',
    'covered',
    'takeaway',
    'delivery',
    'outdoor_seating',
    'indoor_seating',
    'material',
    'colour',
    'cuisine',
    'vending',
    'shelter_type',
    'board_type',
    'artwork_type',
    'memorial',
    'memorial:type',
    'tower:type',
    'post_box:type',
    'recycling_type',
    'crossing',
    'kerb',
    'entrance',
    'roof:shape',
    'religion',
    'denomination',
    'social_facility',
    'toilets',
    'bench',
    'shelter',
    'bin',
    'backrest',
    'armrest',
    'handrail',
    'air_conditioning',
    'drive_through',
    'reservation',
  };

  /// Strict closed-vocabulary value sets for high-frequency OSM attributes where
  /// LLMs commonly hallucinate English synonyms (e.g. `access=public`, `fee=free`,
  /// `wheelchair=accessible`, `source=GPS`).
  static const Map<String, Set<String>> _strictKeyValidValues = {
    'source': {
      'survey',
      'local_knowledge',
      'local knowledge',
      'knowledge',
      'aerial',
      'aerial_imagery',
      'aerial imagery',
      'imagery',
      'bing',
      'esri',
      'mapbox',
      'maxar',
      'mapillary',
      'panoramax',
      'kartaview',
      'streetlevel_imagery',
      'streetlevel imagery',
      'osm_notes',
      'osm notes',
      'extrapolation',
      'estimation',
      'historical',
      'cadastre',
      'photo',
      'photograph',
      'sign',
      'signpost',
      'website',
      'official',
      'opendata',
      'open_data',
    },
    'access': {
      'yes',
      'no',
      'private',
      'permissive',
      'destination',
      'customers',
      'delivery',
      'forestry',
      'agricultural',
      'designated',
      'discouraged',
      'military',
      'permit',
      'use_sidepath',
    },
    'wheelchair': {'yes', 'no', 'limited', 'designated'},
    'internet_access': {'wlan', 'terminal', 'yes', 'no', 'wired', 'service'},
    'smoking': {'yes', 'no', 'separated', 'isolated', 'outside', 'dedicated'},
    'fee': {'yes', 'no', 'donation'},
    'lit': {
      'yes',
      'no',
      '24/7',
      'automatic',
      'limited',
      'sunset-sunrise',
      'disused',
    },
    'parking': {
      'surface',
      'multi-storey',
      'underground',
      'street_side',
      'lane',
      'rooftops',
      'carports',
      'shed_boxes',
      'garage_boxes',
      'half_on_kerb',
      'on_kerb',
      'shoulder',
    },
    'smoothness': {
      'excellent',
      'good',
      'intermediate',
      'bad',
      'very_bad',
      'horrible',
      'very_horrible',
      'impassable',
    },
    'tracktype': {'grade1', 'grade2', 'grade3', 'grade4', 'grade5'},
    'sac_scale': {
      'hiking',
      'mountain_hiking',
      'demanding_mountain_hiking',
      'alpine_hiking',
      'demanding_alpine_hiking',
      'difficult_alpine_hiking',
    },
    'trail_visibility': {
      'excellent',
      'good',
      'intermediate',
      'bad',
      'horrible',
      'no',
    },
    'leaf_type': {'broadleaved', 'needleleaved', 'mixed', 'leafless'},
    'leaf_cycle': {
      'evergreen',
      'deciduous',
      'semi_evergreen',
      'semi_deciduous',
      'mixed',
    },
    'oneway': {'yes', 'no', '-1', 'reversible', 'alternating'},
    'tactile_paving': {'yes', 'no', 'incorrect', 'primitive'},
    'covered': {'yes', 'no', 'arcade', 'colonnade', 'booth', 'partial'},
    'takeaway': {'yes', 'no', 'only'},
    'delivery': {'yes', 'no', 'only'},
    'outdoor_seating': {
      'yes',
      'no',
      'terrace',
      'patio',
      'garden',
      'sidewalk',
      'street',
      'roof',
      'balcony',
      'backyard',
      'pedestrian_zone',
      'parklet',
    },
    'indoor_seating': {'yes', 'no'},
    'toilets': {'yes', 'no'},
    'toilets:wheelchair': {'yes', 'no', 'limited'},
    'bench': {'yes', 'no'},
    'shelter': {'yes', 'no'},
    'bin': {'yes', 'no'},
    'backrest': {'yes', 'no'},
    'armrest': {'yes', 'no'},
    'handrail': {'yes', 'no'},
    'air_conditioning': {'yes', 'no'},
    'drive_through': {'yes', 'no', 'only'},
    'reservation': {'yes', 'no', 'required', 'recommended', 'members_only'},
  };

  /// Common LLM synonym hallucinations mapped cleanly to documented OSM Wiki values.
  static const Map<String, Map<String, String>> _strictKeyValueAliases = {
    'access': {
      'public': 'yes',
      'open': 'yes',
      'free': 'yes',
      'allowed': 'yes',
      'restricted': 'private',
      'members': 'private',
      'members_only': 'private',
      'residents': 'private',
      'customers_only': 'customers',
      'closed': 'no',
      'forbidden': 'no',
      'prohibited': 'no',
    },
    'wheelchair': {
      'accessible': 'yes',
      'true': 'yes',
      'partial': 'limited',
      'partially': 'limited',
      'partially_accessible': 'limited',
      'inaccessible': 'no',
      'not_accessible': 'no',
      'false': 'no',
    },
    'internet_access': {
      'wifi': 'wlan',
      'wi-fi': 'wlan',
      'wireless': 'wlan',
      'free': 'wlan',
      'free_wifi': 'wlan',
      'true': 'wlan',
      'false': 'no',
      'none': 'no',
    },
    'smoking': {
      'prohibited': 'no',
      'forbidden': 'no',
      'banned': 'no',
      'non-smoking': 'no',
      'non_smoking': 'no',
      'no_smoking': 'no',
      'smoke_free': 'no',
      'false': 'no',
      'allowed': 'yes',
      'true': 'yes',
      'outdoor': 'outside',
      'outdoors': 'outside',
      'patio': 'outside',
      'terrace': 'outside',
    },
    'fee': {
      'free': 'no',
      'none': 'no',
      'false': 'no',
      'paid': 'yes',
      'required': 'yes',
      'true': 'yes',
    },
    'lit': {
      'illuminated': 'yes',
      'lighted': 'yes',
      'true': 'yes',
      'dark': 'no',
      'unlit': 'no',
      'false': 'no',
    },
    'parking': {
      'lot': 'surface',
      'parking_lot': 'surface',
      'open': 'surface',
      'outdoor': 'surface',
      'garage': 'multi-storey',
      'multistorey': 'multi-storey',
      'multi_storey': 'multi-storey',
      'structure': 'multi-storey',
      'indoor': 'underground',
    },
    'leaf_type': {
      'deciduous': 'broadleaved',
      'coniferous': 'needleleaved',
      'evergreen': 'needleleaved',
    },
    'tactile_paving': {'true': 'yes', 'false': 'no'},
    'covered': {'true': 'yes', 'false': 'no'},
    'takeaway': {'true': 'yes', 'false': 'no'},
    'delivery': {'true': 'yes', 'false': 'no'},
    'outdoor_seating': {'true': 'yes', 'false': 'no'},
    'indoor_seating': {'true': 'yes', 'false': 'no'},
    'toilets': {'true': 'yes', 'false': 'no'},
    'toilets:wheelchair': {'true': 'yes', 'false': 'no', 'accessible': 'yes'},
    'bench': {'true': 'yes', 'false': 'no'},
    'shelter': {'true': 'yes', 'false': 'no'},
    'bin': {'true': 'yes', 'false': 'no'},
    'backrest': {'true': 'yes', 'false': 'no'},
    'armrest': {'true': 'yes', 'false': 'no'},
    'handrail': {'true': 'yes', 'false': 'no'},
    'air_conditioning': {'true': 'yes', 'false': 'no'},
    'drive_through': {'true': 'yes', 'false': 'no'},
    'reservation': {'true': 'yes', 'false': 'no'},
  };

  /// Placeholder/uncertainty values that LLMs often hallucinate when a field is
  /// unreadable or missing — these are NEVER valid OSM tag values.
  static const Set<String> _placeholderHallucinationValues = {
    'unknown',
    'n/a',
    'na',
    'null',
    'undefined',
    'tbd',
    'todo',
    'not_visible',
    'not visible',
    'not_specified',
    'not specified',
    'unspecified',
    'not_applicable',
    'not applicable',
    'unreadable',
    'illegible',
    'unclear',
    '?',
    '???',
    '-',
    '--',
    '---',
  };

  /// Keys where the literal value `none` is never a valid OSM value.
  static const Set<String> _disallowNoneValueKeys = {
    'name',
    'short_name',
    'alt_name',
    'official_name',
    'brand',
    'operator',
    'cuisine',
    'opening_hours',
    'phone',
    'website',
    'email',
    'amenity',
    'shop',
    'tourism',
    'leisure',
    'highway',
    'building',
    'natural',
    'historic',
    'source',
    'fitness_station',
    'playground',
  };

  /// True when [value] is an obvious LLM uncertainty placeholder (e.g. `unknown`,
  /// `N/A`, `not_visible`) rather than a real OpenStreetMap tag value.
  static bool isPlaceholderHallucinationValue(String value, {String? key}) {
    final vl = value.trim().toLowerCase();
    if (vl.isEmpty) return true;
    if (_placeholderHallucinationValues.contains(vl)) return true;
    if (vl == 'none' && key != null) {
      final kl = key.trim().toLowerCase();
      if (_disallowNoneValueKeys.contains(kl) || kl.startsWith('name:')) {
        return true;
      }
    }
    return false;
  }

  /// True when [key] expects a documented OpenStreetMap controlled vocabulary
  /// value (either a primary feature key or a controlled secondary attribute).
  static bool isControlledVocabularyKey(String key) {
    final kl = key.trim().toLowerCase();
    return _primaryFeatureKeys.contains(kl) ||
        _controlledSecondaryKeys.contains(kl);
  }

  /// Normalizes a strict controlled-vocabulary key's value if it is valid or
  /// maps via a documented alias; returns `null` when [value] is fabricated.
  /// Returns [value] unchanged for keys without a strict closed vocabulary.
  static String? normalizeStrictVocabularyValue(String key, String value) {
    final kl = key.trim().toLowerCase();
    final validSet = _strictKeyValidValues[kl];
    if (validSet == null) return value.trim();

    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '_');
    if (normalized.isEmpty) return null;

    if (kl == 'source') {
      final cleanSource = normalizeSourceValue(value);
      final tokens = cleanSource
          .split(';')
          .map((t) => t.trim().toLowerCase())
          .where((t) => t.isNotEmpty)
          .toList();
      if (tokens.isEmpty) return null;
      if (tokens.every((t) => validSet.contains(t))) {
        return cleanSource;
      }
      return null;
    }

    final aliases = _strictKeyValueAliases[kl];
    final aliased = aliases?[normalized] ??
        aliases?[value.trim().toLowerCase()] ??
        normalized;
    if (validSet.contains(aliased)) return aliased;
    if (validSet.contains(value.trim().toLowerCase())) {
      return value.trim().toLowerCase();
    }
    return null;
  }

  /// True when an `opening_hours` value looks like free-form English prose
  /// (common LLM hallucination) rather than valid OSM `Key:opening_hours` syntax.
  static bool isLikelyProseOpeningHours(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    final lower = v.toLowerCase();
    if (lower == '24/7' || lower == 'unknown') return lower == 'unknown';
    return RegExp(
      r'\b(daily|everyday|every\s+day|usually|normally|typically|approximately|'
      r'around|varies|variable|seasonal|check\s+website|see\s+website|'
      r'open\s+from|except|morning|afternoon|evening|weekdays|weekends)\b',
      caseSensitive: false,
    ).hasMatch(v);
  }

  /// True when a `key=value` pair is already verified offline via our curated
  /// OSM catalog or documented structured vocabularies.
  static bool isKnownVerifiedTagPair(String key, String value) {
    final kl = key.trim().toLowerCase();
    final vl = value.trim().toLowerCase();
    if (kl.isEmpty || vl.isEmpty) return false;
    if (kl == 'source') {
      if (isLegacyOrInvalidSource(value)) return false;
      final validSources = _strictKeyValidValues['source']!;
      final tokens = value
          .split(';')
          .map((t) => t.trim().toLowerCase())
          .where((t) => t.isNotEmpty)
          .toList();
      return tokens.isNotEmpty && tokens.every(validSources.contains);
    }
    if (OsmTagCatalog.knownTagPairs.contains('$kl=$vl')) return true;
    if (kl == 'fitness_station') {
      return _validFitnessStationValues.contains(vl);
    }
    if (kl == 'playground') {
      return _validPlaygroundValues.contains(vl);
    }
    final strictValid = _strictKeyValidValues[kl];
    if (strictValid != null) {
      return strictValid.contains(vl);
    }
    if (vl == 'yes' || vl == 'no' || vl == 'limited' || vl == 'designated') {
      return isKnownOsmKey(kl);
    }
    return false;
  }

  /// Keys whose values are strictly deprecated aliases for `opening_hours` off-days.
  static const Set<String> _dayOffKeys = {
    'day_off',
    'days_off',
    'closed_days',
    'closing_days',
    'closing_day',
    'rest_day',
    'opening_hours:day_off',
    'opening_hours:closed',
  };

  /// Non-standard aliases for `opening_hours`.
  static const Set<String> _openingHoursAliases = {
    'open_hours',
    'business_hours',
    'hours',
  };

  /// Standard OSM boolean keys where `true`/`false` should be `yes`/`no`.
  static const Set<String> _yesNoKeys = {
    'wheelchair',
    'lit',
    'fee',
    'covered',
    'takeaway',
    'outdoor_seating',
    'indoor_seating',
    'smoking',
    'tactile_paving',
    'handrail',
    'hiking',
    'toilets',
    'toilets:wheelchair',
    'drive_through',
    'delivery',
    'reservation',
    'air_conditioning',
    'bench',
    'shelter',
    'bin',
    'dog',
    'backrest',
    'armrest',
  };

  /// Returns true when [latitude] / [longitude] represent a real, non-Null-Island GPS fix.
  static bool hasValidGps(double latitude, double longitude) {
    if (latitude.isNaN || longitude.isNaN) return false;
    if (latitude.abs() < 0.0001 && longitude.abs() < 0.0001) return false;
    return latitude.abs() <= 90.0 && longitude.abs() <= 180.0;
  }

  /// Standard OpenStreetMap `source` tag value for on-the-ground field surveys.
  /// Always uses `survey` (official OSM Wiki `Tag:source=survey`) — never `GPS`
  /// or the software/app name.
  static String recommendedSource({bool hasGpsFix = true}) => 'survey';

  /// True if a `source` value erroneously embeds the software name (e.g. "Edge Mapper ...").
  static bool isLegacySoftwareSource(String value) {
    final lower = value.trim().toLowerCase();
    return lower.startsWith('edge mapper') || lower.contains('edge_mapper');
  }

  /// True if a `source` value contains a `GPS` token (e.g. `GPS` or `survey;GPS`),
  /// which is not a valid standard OSM `source` value.
  static bool hasInvalidSourceGps(String value) {
    final tokens = value
        .split(';')
        .map((t) => t.trim().toLowerCase())
        .where((t) => t.isNotEmpty);
    return tokens.any((t) => t == 'gps');
  }

  /// True if a `source` value uses a legacy software name or invalid `GPS` token.
  static bool isLegacyOrInvalidSource(String value) =>
      isLegacySoftwareSource(value) || hasInvalidSourceGps(value);

  /// Normalizes a `source` tag value by replacing legacy software names and
  /// stripping invalid `GPS` tokens (e.g. `survey;GPS` -> `survey`, `GPS` -> `survey`).
  static String normalizeSourceValue(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || isLegacySoftwareSource(trimmed)) {
      return 'survey';
    }
    final cleaned = <String>[];
    final seenLower = <String>{};
    for (final part in trimmed.split(';')) {
      final token = part.trim();
      if (token.isEmpty) continue;
      final lower = token.toLowerCase();
      if (lower == 'gps' || isLegacySoftwareSource(token)) continue;
      if (seenLower.add(lower)) {
        cleaned.add(token);
      }
    }
    if (cleaned.isEmpty) return 'survey';
    return cleaned.join(';');
  }

  /// True when [tags] describe an actual camera feature where `camera:direction`
  /// is a genuine OpenStreetMap tag (surveillance or speed camera).
  static bool isCameraFeature(Map<String, String> tags) {
    return tags['man_made'] == 'surveillance' ||
        tags['highway'] == 'speed_camera' ||
        tags.containsKey('surveillance:type');
  }

  /// True when [key] is local capture telemetry or changeset-only metadata that
  /// is NOT published to OpenStreetMap elements.
  static bool isLocalOnlyTag(String key, [Map<String, String> allTags = const {}]) {
    final k = key.trim();
    if (k == 'created_by') return true;
    if (k == 'camera:direction' && !isCameraFeature(allTags)) return true;
    return false;
  }

  /// Splits [tags] into publishable OpenStreetMap tags vs local-only capture metadata
  /// so the UI can make publication visibility unambiguous.
  static ({
    Map<String, String> publishable,
    Map<String, String> localOnly,
  }) splitTagsForDisplay(Map<String, String> tags) {
    final publishable = <String, String>{};
    final localOnly = <String, String>{};
    for (final entry in tags.entries) {
      if (isLocalOnlyTag(entry.key, tags)) {
        localOnly[entry.key] = entry.value;
      } else {
        publishable[entry.key] = entry.value;
      }
    }
    return (publishable: publishable, localOnly: localOnly);
  }

  /// Builds the authoritative OpenStreetMap Wiki documentation URL for [key] (and optional [value]).
  static String wikiUrlForTag(String key, [String? value]) {
    final cleanKey = key.trim();
    final cleanVal = value?.trim() ?? '';
    if (cleanKey.isEmpty) return '$osmWikiBaseUrl/Map_features';

    if (cleanKey.startsWith('name:')) {
      return '$osmWikiBaseUrl/Key:name';
    }
    if (cleanKey.startsWith('addr:')) {
      return '$osmWikiBaseUrl/Key:addr';
    }
    if (cleanKey.startsWith('payment:')) {
      return '$osmWikiBaseUrl/Key:payment';
    }
    if (cleanKey.startsWith('currency:')) {
      return '$osmWikiBaseUrl/Key:currency';
    }
    if (cleanKey.startsWith('contact:')) {
      return '$osmWikiBaseUrl/Key:contact';
    }

    if (_primaryFeatureKeys.contains(cleanKey) &&
        cleanVal.isNotEmpty &&
        cleanVal != 'yes' &&
        !cleanVal.contains('*') &&
        !cleanVal.contains('<')) {
      return '$osmWikiBaseUrl/Tag:${Uri.encodeComponent('$cleanKey=$cleanVal')}';
    }

    return '$osmWikiBaseUrl/Key:${Uri.encodeComponent(cleanKey)}';
  }

  /// Inspects [tags] and returns notices for any deprecated, discouraged, or
  /// legacy software-source tags found (for UI warnings & pre-publish checks).
  static List<DeprecatedTagNotice> findDeprecatedTags(
    Map<String, String> tags, {
    bool hasGpsFix = true,
  }) {
    final notices = <DeprecatedTagNotice>[];

    for (final entry in tags.entries) {
      final k = entry.key.trim();
      final v = entry.value.trim();
      if (k.isEmpty || v.isEmpty) continue;
      final kl = k.toLowerCase();
      final vl = v.toLowerCase();

      if (kl != 'note' &&
          kl != 'fixme' &&
          isPlaceholderHallucinationValue(v, key: k)) {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason:
                '"$k=$v" looks like an AI placeholder value rather than real OpenStreetMap data.',
            replacementSummary: 'Remove placeholder tag "$k"',
            canAutoFix: true,
            isInvalidTag: true,
            wikiUrl: wikiUrlForTag(k),
          ),
        );
        continue;
      }

      if (_dayOffKeys.contains(kl)) {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason:
                '"$k" is deprecated on OpenStreetMap. Closed days belong inside "opening_hours" (which supports days before hours, e.g. Tu-Su 09:00-18:00 or Mo-Fr 09:00-18:00; We off).',
            replacementSummary: 'Merge into opening_hours',
            canAutoFix: true,
            wikiUrl: openingHoursWikiUrl,
          ),
        );
        continue;
      }

      if (_openingHoursAliases.contains(kl)) {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason: '"$k" is non-standard on OpenStreetMap; use "opening_hours".',
            replacementSummary: 'opening_hours=$v',
            canAutoFix: true,
            wikiUrl: openingHoursWikiUrl,
          ),
        );
        continue;
      }

      if (kl == 'opening_hours' && isLikelyProseOpeningHours(v)) {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason:
                '"opening_hours=$v" looks like free-form text rather than valid OSM opening_hours syntax (e.g. Mo-Fr 09:00-18:00).',
            replacementSummary: 'Edit to valid OSM opening_hours or remove',
            canAutoFix: false,
            isInvalidTag: true,
            wikiUrl: openingHoursWikiUrl,
          ),
        );
        continue;
      }

      if (kl == 'source' && isLegacyOrInvalidSource(v)) {
        final target = normalizeSourceValue(v);
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason: hasInvalidSourceGps(v)
                ? '"GPS" is not a valid OSM "source" value; use "$target" instead.'
                : 'OSM "source" should reflect the survey method ("$target"), not the app name.',
            replacementSummary: 'source=$target',
            canAutoFix: true,
            isInvalidTag: true,
            wikiUrl: '$osmWikiBaseUrl/Key:source',
          ),
        );
        continue;
      }

      if (kl == 'wifi') {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason: '"wifi" is deprecated on OpenStreetMap in favor of "internet_access".',
            replacementSummary: vl == 'free'
                ? 'internet_access=wlan + internet_access:fee=no'
                : 'internet_access=wlan',
            canAutoFix: true,
            wikiUrl: '$osmWikiBaseUrl/Key:internet_access',
          ),
        );
        continue;
      }

      if (kl == 'phone_number' || kl == 'telephone' || kl == 'tel') {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason: '"$k" is non-standard; OpenStreetMap uses "phone".',
            replacementSummary: 'phone=$v',
            canAutoFix: true,
            wikiUrl: '$osmWikiBaseUrl/Key:phone',
          ),
        );
        continue;
      }

      if (kl == 'email_address') {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason: '"email_address" is non-standard; OpenStreetMap uses "email".',
            replacementSummary: 'email=$v',
            canAutoFix: true,
            wikiUrl: '$osmWikiBaseUrl/Key:email',
          ),
        );
        continue;
      }

      if (kl == 'url') {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason:
                'For POI official web pages, OpenStreetMap recommends "website" instead of "url".',
            replacementSummary: 'website=$v',
            canAutoFix: true,
            wikiUrl: '$osmWikiBaseUrl/Key:website',
          ),
        );
        continue;
      }

      if (kl == 'zip' || kl == 'addr:zip' || kl == 'postal_code') {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason: 'Use standard "addr:postcode" for POI postal codes on OpenStreetMap.',
            replacementSummary: 'addr:postcode=$v',
            canAutoFix: true,
            wikiUrl: '$osmWikiBaseUrl/Key:addr:postcode',
          ),
        );
        continue;
      }

      if (kl == 'handicap' || kl == 'disabled') {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason: '"$k" is deprecated on OpenStreetMap; use "wheelchair".',
            replacementSummary: 'wheelchair=${_normalizeYesNo(v)}',
            canAutoFix: true,
            wikiUrl: '$osmWikiBaseUrl/Key:wheelchair',
          ),
        );
        continue;
      }

      if (kl == 'wood') {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason: '"wood=*" is deprecated on OpenStreetMap; use "leaf_type=*".',
            replacementSummary: 'leaf_type=$v',
            canAutoFix: true,
            wikiUrl: '$osmWikiBaseUrl/Key:leaf_type',
          ),
        );
        continue;
      }

      // Deprecated key=value feature tags
      final pair = '$kl=$vl';
      final pairReplacement = _deprecatedPairReplacements[pair];
      if (pairReplacement != null) {
        final summary = pairReplacement.entries
            .map((e) => '${e.key}=${e.value}')
            .join(' + ');
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason: '"$k=$v" is deprecated on OpenStreetMap.',
            replacementSummary: summary,
            canAutoFix: true,
            wikiUrl: wikiUrlForTag(k, v),
          ),
        );
        continue;
      }

      if (pair == 'amenity=public_building') {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason:
                '"amenity=public_building" is deprecated; use a specific tag such as "office=government" or "building=public".',
            replacementSummary: 'office=government or building=public',
            canAutoFix: false,
            wikiUrl: wikiUrlForTag(k, v),
          ),
        );
        continue;
      }

      if (pair == 'surface=cobblestone') {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason:
                '"surface=cobblestone" is deprecated on OpenStreetMap; prefer "surface=sett" (flat) or "surface=unhewn_cobblestone".',
            replacementSummary: 'surface=sett',
            canAutoFix: true,
            wikiUrl: '$osmWikiBaseUrl/Key:surface',
          ),
        );
        continue;
      }

      if (pair == 'natural=land') {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason: '"natural=land" is deprecated on OpenStreetMap.',
            replacementSummary: 'Remove or use a specific natural/landuse tag',
            canAutoFix: false,
            wikiUrl: deprecatedFeaturesWikiUrl,
          ),
        );
        continue;
      }

      // Hallucinated / non-existent fitness equipment keys (e.g. fitness_equipment=monkey_bars)
      if (_hallucinatedFitnessKeys.contains(kl)) {
        final mapped = normalizeFitnessStationValue(v);
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason:
                '"$k" does not exist on OpenStreetMap. Outdoor fitness equipment uses "fitness_station=*" (or "playground=*" on children playgrounds).',
            replacementSummary: mapped != null
                ? 'fitness_station=$mapped'
                : 'Remove non-existent tag "$k"',
            canAutoFix: true,
            wikiUrl: '$osmWikiBaseUrl/Key:fitness_station',
          ),
        );
        continue;
      }

      // Hallucinated / non-existent playground equipment keys
      if (_hallucinatedPlaygroundKeys.contains(kl)) {
        final mapped = normalizePlaygroundValue(v);
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason:
                '"$k" does not exist on OpenStreetMap. Playground equipment uses "playground=*".',
            replacementSummary: mapped != null
                ? 'playground=$mapped'
                : 'Remove non-existent tag "$k"',
            canAutoFix: true,
            wikiUrl: '$osmWikiBaseUrl/Key:playground',
          ),
        );
        continue;
      }

      // Generic non-OSM "equipment=*" key
      if (kl == 'equipment') {
        final isPlay = tags['leisure']?.trim().toLowerCase() == 'playground';
        final mappedPlay = isPlay ? normalizePlaygroundValue(v) : null;
        final mappedFit = !isPlay ? normalizeFitnessStationValue(v) : null;
        final rep = mappedPlay != null
            ? 'playground=$mappedPlay'
            : (mappedFit != null
                ? 'fitness_station=$mappedFit'
                : 'Remove non-existent tag "equipment"');
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason:
                '"equipment" is not a valid OpenStreetMap feature key. Use "fitness_station=*" or "playground=*".',
            replacementSummary: rep,
            canAutoFix: true,
            wikiUrl: isPlay
                ? '$osmWikiBaseUrl/Key:playground'
                : '$osmWikiBaseUrl/Key:fitness_station',
          ),
        );
        continue;
      }

      // US spelling "color" -> British OSM "colour"
      if (kl == 'color') {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason: 'OpenStreetMap uses British spelling "colour" instead of "color".',
            replacementSummary: 'colour=$v',
            canAutoFix: true,
            wikiUrl: '$osmWikiBaseUrl/Key:colour',
          ),
        );
        continue;
      }

      // Alias value on real fitness_station / playground key (e.g. fitness_station=monkey_bars -> horizontal_ladder)
      if (kl == 'fitness_station') {
        final norm = normalizeFitnessStationValue(v);
        if (norm == null) {
          notices.add(
            DeprecatedTagNotice(
              key: k,
              value: v,
              reason:
                  '"fitness_station=$v" is not a documented OpenStreetMap fitness_station value.',
              replacementSummary: 'Use a documented Key:fitness_station value or remove',
              canAutoFix: false,
              isInvalidTag: true,
              wikiUrl: '$osmWikiBaseUrl/Key:fitness_station',
            ),
          );
          continue;
        } else if (norm != vl) {
          notices.add(
            DeprecatedTagNotice(
              key: k,
              value: v,
              reason:
                  'OpenStreetMap Wiki documents "$norm" for fitness_station instead of "$v".',
              replacementSummary: 'fitness_station=$norm',
              canAutoFix: true,
              wikiUrl: '$osmWikiBaseUrl/Key:fitness_station',
            ),
          );
          continue;
        }
      }

      if (kl == 'playground') {
        final norm = normalizePlaygroundValue(v);
        if (norm == null) {
          notices.add(
            DeprecatedTagNotice(
              key: k,
              value: v,
              reason:
                  '"playground=$v" is not a documented OpenStreetMap playground equipment value.',
              replacementSummary: 'Use a documented Key:playground value or remove',
              canAutoFix: false,
              isInvalidTag: true,
              wikiUrl: '$osmWikiBaseUrl/Key:playground',
            ),
          );
          continue;
        } else if (norm != vl) {
          notices.add(
            DeprecatedTagNotice(
              key: k,
              value: v,
              reason:
                  'OpenStreetMap Wiki documents "$norm" for playground instead of "$v".',
              replacementSummary: 'playground=$norm',
              canAutoFix: true,
              wikiUrl: '$osmWikiBaseUrl/Key:playground',
            ),
          );
          continue;
        }
      }

      // Strict controlled-vocabulary secondary OSM keys (e.g. access=public, fee=free, wheelchair=accessible)
      if (_strictKeyValidValues.containsKey(kl) && kl != 'source') {
        final norm = normalizeStrictVocabularyValue(kl, v);
        if (norm == null) {
          notices.add(
            DeprecatedTagNotice(
              key: k,
              value: v,
              reason:
                  '"$k=$v" is not a documented OpenStreetMap value for "$k".',
              replacementSummary: 'Use a documented OSM value for "$k" or remove',
              canAutoFix: false,
              isInvalidTag: true,
              wikiUrl: wikiUrlForTag(k),
            ),
          );
          continue;
        } else if (norm != vl) {
          notices.add(
            DeprecatedTagNotice(
              key: k,
              value: v,
              reason:
                  'OpenStreetMap uses "$k=$norm" instead of "$k=$v".',
              replacementSummary: '$kl=$norm',
              canAutoFix: true,
              wikiUrl: wikiUrlForTag(k),
            ),
          );
          continue;
        }
      }

      // Catch any other unrecognized / undocumented OSM key (ignore local-only capture tags)
      if (!isLocalOnlyTag(k, tags) && !isKnownOsmKey(k)) {
        notices.add(
          DeprecatedTagNotice(
            key: k,
            value: v,
            reason:
                '"$k" is not a recognized OpenStreetMap Wiki key and may not exist on OpenStreetMap.',
            replacementSummary: 'Verify on OSM Wiki or remove "$k"',
            canAutoFix: false,
            isInvalidTag: true,
            wikiUrl: wikiUrlForTag(k),
          ),
        );
        continue;
      }
    }

    return notices;
  }

  /// Safe, unambiguous 1-to-1 / 1-to-many replacements for deprecated OSM `key=value` pairs.
  static const Map<String, Map<String, String>> _deprecatedPairReplacements = {
    'amenity=gym': {'leisure': 'fitness_centre'},
    'amenity=sauna': {'leisure': 'sauna'},
    'amenity=swimming_pool': {'leisure': 'swimming_pool'},
    'amenity=emergency_phone': {'emergency': 'phone'},
    'amenity=shop': {'shop': 'yes'},
    'amenity=ev_charging': {'amenity': 'charging_station'},
    'shop=fish': {'shop': 'seafood'},
    'shop=betting': {'shop': 'bookmaker'},
    'shop=travel_agent': {'shop': 'travel_agency'},
    'shop=estate_agent': {'office': 'estate_agent'},
    'shop=insurance': {'office': 'insurance'},
    'shop=lawyer': {'office': 'lawyer'},
    'shop=organic': {'shop': 'supermarket', 'organic': 'only'},
    'highway=ford': {'ford': 'yes'},
    'landuse=wood': {'natural': 'wood'},
    'natural=marsh': {'natural': 'wetland', 'wetland': 'marsh'},
    'man_made=water_tank': {'man_made': 'storage_tank', 'content': 'water'},
    'power=sub_station': {'power': 'substation'},
    'tourism=bed_and_breakfast': {
      'tourism': 'guest_house',
      'guest_house': 'bed_and_breakfast',
    },
    'building=entrance': {'entrance': 'yes'},
  };

  /// Automatically modernizes [rawTags] to follow current OpenStreetMap Wiki
  /// conventions:
  /// - Drops AI uncertainty placeholder values (`unknown`, `N/A`, `not_visible`, etc.).
  /// - Converts deprecated `day_off` / `closed_days` into standard `opening_hours`
  ///   syntax (putting open days before hours, e.g. `Tu-Su 09:00-18:00`).
  /// - Normalizes `opening_hours` weekday names (`Mon` -> `Mo`, etc.) and times.
  /// - Replaces deprecated keys/values (`amenity=gym`, `shop=fish`, `wifi`, etc.)
  ///   and normalizes strict controlled-vocabulary values (`access=public` -> `yes`, etc.).
  /// - Replaces legacy software-name and invalid `GPS` `source` values with `survey`.
  /// - Optionally strips local-only non-OSM tags (`camera:direction` on non-camera
  ///   POIs, `created_by`) when [stripLocalOnly] is true.
  static Map<String, String> modernizeTags(
    Map<String, String> rawTags, {
    bool hasGpsFix = true,
    bool stripLocalOnly = false,
    bool dropUnknownKeys = false,
  }) {
    final result = <String, String>{};
    final collectedDayOffValues = <String>[];
    String? rawOpeningHours;
    final leisureHint = rawTags['leisure']?.trim().toLowerCase() ?? '';

    // First pass: trim, strip empty, collect opening_hours & deprecated day_off aliases
    for (final entry in rawTags.entries) {
      final k = entry.key.trim();
      final v = entry.value.trim();
      if (k.isEmpty || v.isEmpty) continue;

      final kl = k.toLowerCase();

      if (stripLocalOnly && isLocalOnlyTag(k, rawTags)) {
        continue;
      }

      if (kl == 'created_by') {
        // Deprecated on OSM elements (belongs only on changesets)
        continue;
      }

      // Drop obvious LLM placeholder hallucinations (e.g. "unknown", "N/A", "not_visible")
      if (kl != 'note' &&
          kl != 'fixme' &&
          isPlaceholderHallucinationValue(v, key: k)) {
        continue;
      }

      if (_dayOffKeys.contains(kl)) {
        collectedDayOffValues.add(v);
        continue;
      }

      if (kl == 'opening_hours') {
        rawOpeningHours = v;
        continue;
      }

      if (_openingHoursAliases.contains(kl)) {
        rawOpeningHours ??= v;
        continue;
      }

      // Normalize legacy software-name and invalid GPS source -> survey
      if (kl == 'source') {
        result['source'] = normalizeSourceValue(v);
        continue;
      }

      // Deprecated key migrations
      if (kl == 'wifi') {
        final vl = v.toLowerCase();
        if (vl == 'no' || vl == 'false') {
          result.putIfAbsent('internet_access', () => 'no');
        } else {
          result.putIfAbsent('internet_access', () => 'wlan');
          if (vl == 'free') {
            result.putIfAbsent('internet_access:fee', () => 'no');
          }
        }
        continue;
      }

      if (kl == 'phone_number' || kl == 'telephone' || kl == 'tel') {
        result.putIfAbsent('phone', () => v);
        continue;
      }

      if (kl == 'email_address') {
        result.putIfAbsent('email', () => v);
        continue;
      }

      if (kl == 'url') {
        result.putIfAbsent('website', () => v);
        continue;
      }

      if (kl == 'zip' || kl == 'addr:zip' || kl == 'postal_code') {
        result.putIfAbsent('addr:postcode', () => v);
        continue;
      }

      if (kl == 'handicap' || kl == 'disabled') {
        result.putIfAbsent('wheelchair', () => _normalizeYesNo(v));
        continue;
      }

      if (kl == 'wood') {
        result.putIfAbsent('leaf_type', () => v);
        continue;
      }

      // Auto-repair hallucinated fitness / playground equipment keys to real OSM tags
      if (_hallucinatedFitnessKeys.contains(kl)) {
        final mapped = normalizeFitnessStationValue(v);
        if (mapped != null) {
          result.putIfAbsent('fitness_station', () => mapped);
        }
        continue;
      }

      if (_hallucinatedPlaygroundKeys.contains(kl)) {
        final mapped = normalizePlaygroundValue(v);
        if (mapped != null) {
          result.putIfAbsent('playground', () => mapped);
        }
        continue;
      }

      if (kl == 'equipment') {
        if (leisureHint == 'playground') {
          final mapped = normalizePlaygroundValue(v);
          if (mapped != null) {
            result.putIfAbsent('playground', () => mapped);
          }
        } else if (leisureHint == 'fitness_station') {
          final mapped = normalizeFitnessStationValue(v);
          if (mapped != null) {
            result.putIfAbsent('fitness_station', () => mapped);
          }
        }
        continue;
      }

      // Common LLM alias keys -> real OSM keys
      if (kl == 'color') {
        result.putIfAbsent('colour', () => v);
        continue;
      }
      if (kl == 'bench_material' ||
          kl == 'structure_material' ||
          kl == 'frame_material') {
        result.putIfAbsent('material', () => v);
        continue;
      }
      if (kl == 'building_type') {
        result.putIfAbsent('building', () => v);
        continue;
      }
      if (kl == 'parking_type') {
        result.putIfAbsent('parking', () => v);
        continue;
      }
      if (kl == 'shop_type' || kl == 'store_type') {
        result.putIfAbsent('shop', () => v);
        continue;
      }
      if (kl == 'food_type' || kl == 'cuisine_type') {
        result.putIfAbsent('cuisine', () => v);
        continue;
      }
      if (kl == 'lighting') {
        final norm = _normalizeYesNo(v);
        if (norm == 'yes' || norm == 'no') {
          result.putIfAbsent('lit', () => norm);
        }
        continue;
      }
      if (kl == 'accessibility') {
        final norm = _normalizeYesNo(v).toLowerCase();
        if (norm == 'yes' || norm == 'no' || norm == 'limited') {
          result.putIfAbsent('wheelchair', () => norm);
        }
        continue;
      }

      // Normalize structured OSM vocabularies (fitness_station=* & playground=*)
      if (kl == 'fitness_station') {
        final mapped = normalizeFitnessStationValue(v);
        if (mapped != null) {
          result['fitness_station'] = mapped;
        } else if (!dropUnknownKeys) {
          result[k] = v;
        }
        continue;
      }

      if (kl == 'playground') {
        final mapped = normalizePlaygroundValue(v);
        if (mapped != null) {
          result['playground'] = mapped;
        } else if (!dropUnknownKeys) {
          result[k] = v;
        }
        continue;
      }

      // Deprecated key=value pair migrations
      final pair = '$kl=${v.toLowerCase()}';
      if (pair == 'surface=cobblestone') {
        result['surface'] = 'sett';
        continue;
      }
      final replacement = _deprecatedPairReplacements[pair];
      if (replacement != null) {
        for (final rep in replacement.entries) {
          result.putIfAbsent(rep.key, () => rep.value);
        }
        continue;
      }

      // Normalize strict controlled-vocabulary OSM keys (e.g. access=public -> yes,
      // internet_access=free_wifi -> wlan + internet_access:fee=no, fee=free -> no)
      if (_strictKeyValidValues.containsKey(kl) && kl != 'source') {
        if (kl == 'internet_access') {
          final vl = v.toLowerCase().replaceAll(RegExp(r'\s+'), '_');
          if (vl == 'free' || vl == 'free_wifi') {
            result['internet_access'] = 'wlan';
            result.putIfAbsent('internet_access:fee', () => 'no');
            continue;
          }
        }
        final mapped = normalizeStrictVocabularyValue(kl, v);
        if (mapped != null) {
          result[kl] = mapped;
        } else if (!dropUnknownKeys) {
          result[k] = v;
        }
        continue;
      }

      // Strictly drop non-existent / unverified keys when sanitizing AI output
      if (dropUnknownKeys && !isKnownOsmKey(k)) {
        continue;
      }

      // Normalize boolean true/false to yes/no on standard OSM yes/no keys
      if (_yesNoKeys.contains(kl) ||
          kl.startsWith('payment:') ||
          kl.startsWith('diet:') ||
          kl.startsWith('recycling:')) {
        result[k] = _normalizeYesNo(v);
        continue;
      }

      result[k] = v;
    }

    // Merge any deprecated day_off into opening_hours & normalize opening_hours syntax
    if (rawOpeningHours != null || collectedDayOffValues.isNotEmpty) {
      final mergedHours = mergeDayOffIntoOpeningHours(
        openingHours: rawOpeningHours,
        dayOffValues: collectedDayOffValues,
      );
      if (mergedHours != null && mergedHours.trim().isNotEmpty) {
        if (!dropUnknownKeys || !isLikelyProseOpeningHours(mergedHours)) {
          result['opening_hours'] = mergedHours;
        }
      }
    }

    return result;
  }

  /// Strictly sanitizes AI-generated OSM tags:
  /// - Modernizes deprecated tags and auto-repairs common LLM hallucinations
  ///   (e.g. `fitness_equipment=monkey_bars` -> `fitness_station=horizontal_ladder`)
  /// - Strips local-only non-OSM tags (`camera:direction`, `created_by`)
  /// - Drops any remaining key that does NOT exist in documented OpenStreetMap
  ///   tagging schemas so AI cannot fabricate non-existent OSM keys.
  static Map<String, String> sanitizeAiTags(
    Map<String, String> rawTags, {
    bool hasGpsFix = true,
  }) {
    return modernizeTags(
      rawTags,
      hasGpsFix: hasGpsFix,
      stripLocalOnly: true,
      dropUnknownKeys: true,
    );
  }

  /// Prepares tags for OpenStreetMap publication/export:
  /// - Modernizes deprecated tags and legacy software-name `source`
  /// - Strips local-only non-OSM tags (`camera:direction` on non-camera POIs, `created_by`)
  /// - Enforces OSM API v0.6 255-char key/value limits.
  static Map<String, String> filterPublishableTags(
    Map<String, String> rawTags, {
    bool hasGpsFix = true,
  }) {
    final modernized = modernizeTags(
      rawTags,
      hasGpsFix: hasGpsFix,
      stripLocalOnly: true,
    );
    final cleaned = <String, String>{};
    for (final entry in modernized.entries) {
      final k = entry.key.trim();
      final v = entry.value.trim();
      if (k.isEmpty || v.isEmpty) continue;
      final safeK = k.length > 255 ? k.substring(0, 255) : k;
      final safeV = v.length > 255 ? v.substring(0, 255) : v;
      cleaned[safeK] = safeV;
    }
    return cleaned;
  }

  static String _normalizeYesNo(String raw) {
    final l = raw.trim().toLowerCase();
    if (l == 'true') return 'yes';
    if (l == 'false') return 'no';
    return raw.trim();
  }

  /// Normalizes an OSM `opening_hours` expression (2-letter weekday codes,
  /// 24h zero-padded times, clean dashes & semicolons) and folds any deprecated
  /// `day_off` values cleanly into it (putting open days before hours whenever possible!).
  static String? mergeDayOffIntoOpeningHours({
    String? openingHours,
    List<String> dayOffValues = const [],
  }) {
    final normalizedHours = openingHours != null && openingHours.trim().isNotEmpty
        ? normalizeOpeningHours(openingHours)
        : null;

    if (dayOffValues.isEmpty) return normalizedHours;

    final combinedOff = dayOffValues.join(', ').trim();
    if (combinedOff.isEmpty || _isNoDayOff(combinedOff)) {
      return normalizedHours;
    }

    final parsed = _parseOffDays(combinedOff);
    final offDays = parsed.weekdays;
    final offPh = parsed.publicHoliday;

    if (offDays.isEmpty && !offPh) {
      // Unrecognized day_off text (e.g. "irregular") — keep valid opening_hours untouched
      return normalizedHours;
    }

    // No opening_hours yet: emit concise OSM off-day rule (e.g. "We off" / "We,PH off")
    if (normalizedHours == null) {
      final parts = <String>[
        if (offDays.isNotEmpty) formatWeekdaySet(offDays),
        if (offPh) 'PH',
      ];
      return '${parts.join(',')} off';
    }

    // Case 1: bare time range(s) with no day selector, e.g. "09:00-18:00" or "11:00-14:00, 17:00-21:00"
    final bareTimePattern = RegExp(
      r'^\d{2}:\d{2}-\d{2}:\d{2}(?:\s*,\s*\d{2}:\d{2}-\d{2}:\d{2})*$',
    );
    if (bareTimePattern.hasMatch(normalizedHours)) {
      final openDays = {0, 1, 2, 3, 4, 5, 6}.difference(offDays);
      final base = openDays.isNotEmpty
          ? '${formatWeekdaySet(openDays)} $normalizedHours'
          : '${formatWeekdaySet(offDays)} off';
      return offPh ? '$base; PH off' : base;
    }

    // Case 2: single "Mo-Su <hours>" rule -> subtract offDays directly so days precede hours!
    final allWeekMatch = RegExp(
      r'^Mo-Su\s+(\d{2}:\d{2}-\d{2}:\d{2}(?:\s*,\s*\d{2}:\d{2}-\d{2}:\d{2})*)$',
    ).firstMatch(normalizedHours);
    if (allWeekMatch != null) {
      final timePart = allWeekMatch.group(1)!;
      final openDays = {0, 1, 2, 3, 4, 5, 6}.difference(offDays);
      final base = openDays.isNotEmpty
          ? '${formatWeekdaySet(openDays)} $timePart'
          : '${formatWeekdaySet(offDays)} off';
      return offPh ? '$base; PH off' : base;
    }

    // Case 3: complex / multi-rule opening_hours -> append standard "; <days> off"
    final offTokens = <String>[
      if (offDays.isNotEmpty) formatWeekdaySet(offDays),
      if (offPh) 'PH',
    ];
    final offClause = '${offTokens.join(',')} off';
    if (normalizedHours.toLowerCase().contains(offClause.toLowerCase())) {
      return normalizedHours;
    }
    return '$normalizedHours; $offClause';
  }

  /// Normalizes English/full/3-letter weekday names and time formatting to strict
  /// OpenStreetMap `opening_hours` syntax (e.g. `Mon-Fri 9:00–18:00` -> `Mo-Fr 09:00-18:00`).
  static String normalizeOpeningHours(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;

    // Normalize fancy dashes and Japanese wave dash to ASCII hyphen
    s = s.replaceAll(RegExp(r'[–—−～〜]'), '-');

    // Normalize common English weekday names (case-insensitive, word boundaries)
    const dayReplacements = <(String, String)>[
      (r'\bmonday\b|\bmon\.?\b', 'Mo'),
      (r'\btuesday\b|\btues?\.?\b', 'Tu'),
      (r'\bwednesday\b|\bwed\.?\b', 'We'),
      (r'\bthursday\b|\bthurs?\.?\b', 'Th'),
      (r'\bfriday\b|\bfri\.?\b', 'Fr'),
      (r'\bsaturday\b|\bsat\.?\b', 'Sa'),
      (r'\bsunday\b|\bsun\.?\b', 'Su'),
      (r'\bpublic\s+holidays?\b', 'PH'),
      (r'\bclosed\b', 'off'),
    ];
    for (final (pattern, replacement) in dayReplacements) {
      s = s.replaceAll(RegExp(pattern, caseSensitive: false), replacement);
    }

    // Normalize "HH:MM to HH:MM" -> "HH:MM-HH:MM"
    s = s.replaceAllMapped(
      RegExp(r'(\d{1,2}:\d{2})\s+to\s+(\d{1,2}:\d{2})', caseSensitive: false),
      (m) => '${m.group(1)}-${m.group(2)}',
    );

    // Zero-pad single-digit hours like "9:00" -> "09:00"
    s = s.replaceAllMapped(
      RegExp(r'(?<!\d)(\d):(\d{2})(?!\d)'),
      (m) => '0${m.group(1)}:${m.group(2)}',
    );

    // Clean spaces around dashes in time ranges ("09:00 - 18:00" -> "09:00-18:00")
    s = s.replaceAllMapped(
      RegExp(r'(\d{2}:\d{2})\s*-\s*(\d{2}:\d{2})'),
      (m) => '${m.group(1)}-${m.group(2)}',
    );

    // Clean spaces around day ranges ("Mo - Fr" -> "Mo-Fr")
    s = s.replaceAllMapped(
      RegExp(r'\b(Mo|Tu|We|Th|Fr|Sa|Su)\s*-\s*(Mo|Tu|We|Th|Fr|Sa|Su)\b'),
      (m) => '${m.group(1)}-${m.group(2)}',
    );

    // Normalize semicolon spacing
    s = s.replaceAll(RegExp(r'\s*;\s*'), '; ');
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return s;
  }

  static bool _isNoDayOff(String raw) {
    final l = raw.trim().toLowerCase();
    return l == 'none' ||
        l == 'no' ||
        l == 'n/a' ||
        l == 'なし' ||
        l == '無休' ||
        l == '年中無休';
  }

  static ({Set<int> weekdays, bool publicHoliday}) _parseOffDays(String raw) {
    final days = <int>{};
    bool ph = false;

    final normalized = normalizeOpeningHours(raw);

    // Detect public holiday mentions (English, French, German, Japanese)
    if (RegExp(r'\bPH\b|holiday|férié|feiertag|祝', caseSensitive: false)
        .hasMatch(normalized)) {
      ph = true;
    }

    // Parse OSM day ranges like "Sa-Su" or "Mo-We"
    final rangeRegex =
        RegExp(r'\b(Mo|Tu|We|Th|Fr|Sa|Su)-(Mo|Tu|We|Th|Fr|Sa|Su)\b');
    for (final m in rangeRegex.allMatches(normalized)) {
      final start = _osmWeekdays.indexOf(m.group(1)!);
      final end = _osmWeekdays.indexOf(m.group(2)!);
      if (start >= 0 && end >= 0) {
        var cur = start;
        for (int i = 0; i < 7; i++) {
          days.add(cur);
          if (cur == end) break;
          cur = (cur + 1) % 7;
        }
      }
    }

    // Parse individual OSM 2-letter codes
    final singleRegex = RegExp(r'\b(Mo|Tu|We|Th|Fr|Sa|Su)\b');
    for (final m in singleRegex.allMatches(normalized)) {
      final idx = _osmWeekdays.indexOf(m.group(1)!);
      if (idx >= 0) days.add(idx);
    }

    // Parse French, German, and Japanese weekday names
    const extraMatchers = <(String, int)>[
      (r'\blundi\b|\bmontag\b|月', 0),
      (r'\bmardi\b|\bdienstag\b|火', 1),
      (r'\bmercredi\b|\bmittwoch\b|水', 2),
      (r'\bjeudi\b|\bdonnerstag\b|木', 3),
      (r'\bvendredi\b|\bfreitag\b|金', 4),
      (r'\bsamedi\b|\bsamstag\b|土', 5),
      (r'\bdimanche\b|\bsonntag\b|日', 6),
    ];
    for (final (pat, idx) in extraMatchers) {
      if (RegExp(pat, caseSensitive: false).hasMatch(raw)) {
        days.add(idx);
      }
    }

    return (weekdays: days, publicHoliday: ph);
  }

  /// Formats a set of weekday indices (0=Mo .. 6=Su) into compact OSM syntax:
  /// - 1 day: `Mo`
  /// - 2 consecutive days: `Mo,Tu`
  /// - 3+ consecutive days: `Tu-Su`, `Mo-Fr`
  static String formatWeekdaySet(Set<int> indices) {
    final sorted = indices.where((i) => i >= 0 && i <= 6).toList()..sort();
    if (sorted.isEmpty) return '';

    final segments = <String>[];
    int start = sorted.first;
    int prev = sorted.first;

    void flush(int s, int e) {
      if (s == e) {
        segments.add(_osmWeekdays[s]);
      } else if (e == s + 1) {
        segments.add('${_osmWeekdays[s]},${_osmWeekdays[e]}');
      } else {
        segments.add('${_osmWeekdays[s]}-${_osmWeekdays[e]}');
      }
    }

    for (var i = 1; i < sorted.length; i++) {
      final cur = sorted[i];
      if (cur == prev + 1) {
        prev = cur;
      } else {
        flush(start, prev);
        start = cur;
        prev = cur;
      }
    }
    flush(start, prev);
    return segments.join(',');
  }
}
