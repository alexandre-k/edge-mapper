import '../models/osm_record.dart';

class OsmTagEntry {
  final String key;
  final String value;
  final String label;
  final String category;
  final List<String> keywords;
  final double typicalDistanceMeters;
  final String description;
  final bool requiresCustomValue;
  final List<String> suggestedValues;

  const OsmTagEntry({
    required this.key,
    required this.value,
    required this.label,
    required this.category,
    this.keywords = const [],
    this.typicalDistanceMeters = 6.0,
    this.description = '',
    this.requiresCustomValue = false,
    this.suggestedValues = const [],
  });

  String get tagString => '$key=$value';
}

class RankedOsmTag {
  final OsmTagEntry entry;
  final double probability; // 0.0 .. 0.99
  final String matchReason;

  const RankedOsmTag({
    required this.entry,
    required this.probability,
    required this.matchReason,
  });

  int get probabilityPercent => (probability * 100).round().clamp(1, 99);
}

/// Comprehensive OpenStreetMap tag catalog + probability ranking engine.
/// Powers the non-free-text OSM Tag Selector (sorted by probability of matching
/// the captured photo/context, with instant search across all OSM tags) AND the
/// complete OSM highway/surface/attribute pickers for route recording.
class OsmTagCatalog {
  static const List<String> categories = [
    'All',
    'Amenity',
    'Shop',
    'Tourism',
    'Highway',
    'Nature',
    'Surface',
    'Accessibility',
    'Attributes',
    'Building',
  ];

  /// Complete standard OpenStreetMap `highway=*` values for paths/streets/trails.
  static const List<(String, String)> allHighwayValues = [
    ('footway', 'Footway / Sidewalk / Park path'),
    ('path', 'Path / Hiking or shared trail'),
    ('pedestrian', 'Pedestrian street / plaza'),
    ('track', 'Track (agricultural / forestry)'),
    ('steps', 'Steps / Stairway'),
    ('cycleway', 'Cycleway / Bike path'),
    ('bridleway', 'Bridleway (horse / multi-use)'),
    ('living_street', 'Living street (shared low-speed)'),
    ('residential', 'Residential street'),
    ('service', 'Service road / alley / park drive'),
    ('unclassified', 'Minor rural road'),
    ('corridor', 'Indoor hallway / corridor'),
    ('via_ferrata', 'Via ferrata (cabled mountain route)'),
    ('road', 'Unknown / unclassified road'),
  ];

  /// Complete standard OpenStreetMap `surface=*` values.
  static const List<(String, String)> allSurfaceValues = [
    ('paved', 'Paved (general)'),
    ('asphalt', 'Asphalt / tarmac'),
    ('concrete', 'Concrete'),
    ('concrete:plates', 'Concrete plates / slabs'),
    ('paving_stones', 'Paving stones / bricks'),
    ('sett', 'Sett / flat cobblestones'),
    ('unhewn_cobblestone', 'Unhewn cobblestone'),
    ('metal', 'Metal grating / bridge deck'),
    ('wood', 'Wood / boardwalk / planks'),
    ('stepping_stones', 'Stepping stones'),
    ('tartan', 'Tartan / running track'),
    ('artificial_turf', 'Artificial turf'),
    ('unpaved', 'Unpaved (general)'),
    ('compacted', 'Compacted crushed stone / park path'),
    ('fine_gravel', 'Fine gravel'),
    ('gravel', 'Gravel'),
    ('pebblestone', 'Pebblestone / shingle'),
    ('ground', 'Natural ground'),
    ('dirt', 'Dirt / soil'),
    ('earth', 'Earth'),
    ('grass', 'Grass'),
    ('mud', 'Mud'),
    ('sand', 'Sand'),
    ('woodchips', 'Woodchips / bark mulch'),
    ('rock', 'Bare rock / bedrock'),
    ('stone', 'Stone'),
    ('snow', 'Snow'),
    ('ice', 'Ice'),
  ];

  static const List<(String, String)> allSmoothnessValues = [
    ('excellent', 'Excellent (rollerblades / smooth)'),
    ('good', 'Good (racing bike / wheelchair)'),
    ('intermediate', 'Intermediate (city bike / stroller)'),
    ('bad', 'Bad (rough / trekking bike)'),
    ('very_bad', 'Very bad (roots / rocks)'),
    ('horrible', 'Horrible (heavy off-road)'),
    ('impassable', 'Impassable'),
  ];

  static const List<(String, String)> allSacScaleValues = [
    ('hiking', 'T1 — Hiking (well-cleared trail)'),
    ('mountain_hiking', 'T2 — Mountain hiking (steep sections)'),
    ('demanding_mountain_hiking', 'T3 — Demanding mountain hiking'),
    ('alpine_hiking', 'T4 — Alpine hiking (hands needed)'),
    ('demanding_alpine_hiking', 'T5 — Demanding alpine'),
    ('difficult_alpine_hiking', 'T6 — Difficult alpine'),
  ];

  static const List<(String, String)> allTrailVisibilityValues = [
    ('excellent', 'Excellent (unambiguous path)'),
    ('good', 'Good (next marker always visible)'),
    ('intermediate', 'Intermediate (mostly visible)'),
    ('bad', 'Bad (sometimes pathless)'),
    ('horrible', 'Horrible (often pathless)'),
    ('no', 'No visibility (cross-country)'),
  ];

  static const List<OsmTagEntry> entries = [
    // --- AMENITIES ---
    OsmTagEntry(
      key: 'amenity',
      value: 'cafe',
      label: 'Cafe / Coffee Shop',
      category: 'Amenity',
      keywords: ['coffee', 'espresso', 'tea', 'bakery', 'カフェ', '珈琲', '喫茶', 'drink', 'cup', 'table'],
      typicalDistanceMeters: 8.0,
      description: 'Sit-down coffee shop or cafe',
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'restaurant',
      label: 'Restaurant',
      category: 'Amenity',
      keywords: ['food', 'dining', 'ramen', 'sushi', 'bistro', '食堂', 'ラーメン', 'izakaya', 'meal', 'menu'],
      typicalDistanceMeters: 9.0,
      description: 'Full-service sit-down restaurant',
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'fast_food',
      label: 'Fast Food / Takeaway',
      category: 'Amenity',
      keywords: ['burger', 'pizza', 'kebab', 'takeaway', 'fast', 'food', 'snack'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'bar',
      label: 'Bar / Izakaya',
      category: 'Amenity',
      keywords: ['bar', 'pub', 'izakaya', '居酒屋', 'alcohol', 'cocktail', 'beer'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'pub',
      label: 'Pub',
      category: 'Amenity',
      keywords: ['pub', 'beer', 'tavern', 'ale'],
      typicalDistanceMeters: 9.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'ice_cream',
      label: 'Ice Cream / Gelato',
      category: 'Amenity',
      keywords: ['ice cream', 'gelato', 'dessert', 'soft serve'],
      typicalDistanceMeters: 7.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'bench',
      label: 'Public Bench',
      category: 'Amenity',
      keywords: ['bench', 'seat', 'park', 'wood', 'rest', 'ベンチ', 'chair'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'drinking_water',
      label: 'Drinking Water Fountain',
      category: 'Amenity',
      keywords: ['water', 'fountain', 'tap', 'drink', '水飲み場', 'hydrant'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'toilets',
      label: 'Public Toilets / Restroom',
      category: 'Amenity',
      keywords: ['toilet', 'wc', 'restroom', 'bathroom', 'トイレ', 'お手洗い'],
      typicalDistanceMeters: 6.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'vending_machine',
      label: 'Vending Machine',
      category: 'Amenity',
      keywords: ['vending', 'machine', 'drink', '自販機', '自動販売機', 'soda'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'post_box',
      label: 'Post Box / Mailbox',
      category: 'Amenity',
      keywords: ['post', 'mail', 'letter', 'ポスト', '郵便', 'red box'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'post_office',
      label: 'Post Office',
      category: 'Amenity',
      keywords: ['post office', '郵便局', 'mail', 'shipping'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'pharmacy',
      label: 'Pharmacy / Drugstore',
      category: 'Amenity',
      keywords: ['pharmacy', 'drugstore', 'medicine', '薬局', 'pharmacie', 'apotheke', 'cross'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'hospital',
      label: 'Hospital',
      category: 'Amenity',
      keywords: ['hospital', 'emergency', 'medical', '病院'],
      typicalDistanceMeters: 18.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'clinic',
      label: 'Medical Clinic',
      category: 'Amenity',
      keywords: ['clinic', 'doctor', 'dental', 'クリニック', '医院'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'bank',
      label: 'Bank',
      category: 'Amenity',
      keywords: ['bank', '銀行', 'finance', 'banque'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'atm',
      label: 'ATM / Cash Machine',
      category: 'Amenity',
      keywords: ['atm', 'cash', 'money', 'bank'],
      typicalDistanceMeters: 3.5,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'place_of_worship',
      label: 'Place of Worship (Shrine/Temple/Church)',
      category: 'Amenity',
      keywords: ['shrine', 'temple', 'church', 'mosque', 'torii', '神社', '寺', '鳥居', 'église', 'kirche', 'architecture'],
      typicalDistanceMeters: 12.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'shelter',
      label: 'Shelter / Rain Pavilion',
      category: 'Amenity',
      keywords: ['shelter', 'pavilion', 'hut', 'roof', 'gazebo', '東屋', 'cabin'],
      typicalDistanceMeters: 6.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'waste_basket',
      label: 'Trash Bin / Waste Basket',
      category: 'Amenity',
      keywords: ['trash', 'bin', 'garbage', 'waste', 'ゴミ箱'],
      typicalDistanceMeters: 2.5,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'recycling',
      label: 'Recycling Containers',
      category: 'Amenity',
      keywords: ['recycle', 'recycling', 'bottle', 'can', 'plastic', 'glass'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'bicycle_parking',
      label: 'Bicycle Parking',
      category: 'Amenity',
      keywords: ['bike', 'bicycle', 'rack', '駐輪場', 'cycle'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'parking',
      label: 'Car Parking',
      category: 'Amenity',
      keywords: ['parking', 'car', 'lot', 'garage', '駐車場', 'vehicle'],
      typicalDistanceMeters: 12.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'charging_station',
      label: 'EV Charging Station',
      category: 'Amenity',
      keywords: ['ev', 'charging', 'electric', 'charger', 'car'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'fuel',
      label: 'Gas / Fuel Station',
      category: 'Amenity',
      keywords: ['gas', 'fuel', 'petrol', 'station', 'ガソリン'],
      typicalDistanceMeters: 15.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'library',
      label: 'Public Library',
      category: 'Amenity',
      keywords: ['library', 'books', '図書館', 'bibliothèque'],
      typicalDistanceMeters: 12.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'school',
      label: 'School',
      category: 'Amenity',
      keywords: ['school', 'academy', '学校', 'école'],
      typicalDistanceMeters: 18.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'police',
      label: 'Police Station / Koban',
      category: 'Amenity',
      keywords: ['police', 'koban', '交番', '警察'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'fountain',
      label: 'Decorative Fountain',
      category: 'Amenity',
      keywords: ['fountain', 'water', 'plaza', '噴水'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'parcel_locker',
      label: 'Parcel Locker',
      category: 'Amenity',
      keywords: ['locker', 'parcel', 'amazon', 'delivery', 'pickup'],
      typicalDistanceMeters: 3.5,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'bbq',
      label: 'Barbecue Grill',
      category: 'Amenity',
      keywords: ['bbq', 'grill', 'picnic', 'fire'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'amenity',
      value: 'community_centre',
      label: 'Community Centre',
      category: 'Amenity',
      keywords: ['community', 'hall', '公民館', 'center'],
      typicalDistanceMeters: 12.0,
    ),

    // --- SHOPS ---
    OsmTagEntry(
      key: 'shop',
      value: 'convenience',
      label: 'Convenience Store',
      category: 'Shop',
      keywords: ['convenience', '7-eleven', 'lawson', 'familymart', 'コンビニ', 'mart', 'store', '24h'],
      typicalDistanceMeters: 9.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'bakery',
      label: 'Bakery / Boulangerie',
      category: 'Shop',
      keywords: ['bakery', 'bread', 'boulangerie', 'patisserie', 'パン', 'bäckerei', 'pastry', 'cake'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'supermarket',
      label: 'Supermarket / Grocery',
      category: 'Shop',
      keywords: ['supermarket', 'grocery', 'market', 'スーパー', 'food'],
      typicalDistanceMeters: 14.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'clothes',
      label: 'Clothing Shop',
      category: 'Shop',
      keywords: ['clothes', 'fashion', 'apparel', 'boutique', 'dress', 'shirt'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'books',
      label: 'Bookshop',
      category: 'Shop',
      keywords: ['book', 'bookstore', '書店', 'librairie', 'manga'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'florist',
      label: 'Florist / Flower Shop',
      category: 'Shop',
      keywords: ['flower', 'florist', 'bouquet', 'plant', '花屋'],
      typicalDistanceMeters: 7.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'hairdresser',
      label: 'Hairdresser / Barber',
      category: 'Shop',
      keywords: ['hair', 'barber', 'salon', '美容室', 'cut'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'greengrocer',
      label: 'Greengrocer / Fruit & Veg',
      category: 'Shop',
      keywords: ['fruit', 'vegetable', 'produce', '八百屋', 'market'],
      typicalDistanceMeters: 7.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'butcher',
      label: 'Butcher',
      category: 'Shop',
      keywords: ['meat', 'butcher', 'boucherie', '精肉'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'bicycle',
      label: 'Bicycle Shop',
      category: 'Shop',
      keywords: ['bicycle', 'bike', 'repair', '自転車'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'electronics',
      label: 'Electronics Shop',
      category: 'Shop',
      keywords: ['electronics', 'computer', 'phone', 'camera', '家電'],
      typicalDistanceMeters: 9.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'hardware',
      label: 'Hardware / DIY Store',
      category: 'Shop',
      keywords: ['hardware', 'tools', 'diy', 'paint'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'gift',
      label: 'Gift / Souvenir Shop',
      category: 'Shop',
      keywords: ['gift', 'souvenir', 'craft', 'お土産'],
      typicalDistanceMeters: 7.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'kiosk',
      label: 'Kiosk / Newsstand',
      category: 'Shop',
      keywords: ['kiosk', 'newsstand', 'ticket', 'stand', 'booth'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'laundry',
      label: 'Laundromat / Dry Cleaning',
      category: 'Shop',
      keywords: ['laundry', 'wash', 'coin', 'cleaning', 'コインランドリー'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'alcohol',
      label: 'Wine / Liquor Shop',
      category: 'Shop',
      keywords: ['wine', 'liquor', 'sake', '酒屋', 'alcohol'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'optician',
      label: 'Optician / Eyewear',
      category: 'Shop',
      keywords: ['glasses', 'optician', 'eyewear', '眼鏡'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'shoes',
      label: 'Shoe Shop',
      category: 'Shop',
      keywords: ['shoe', 'footwear', 'boots', '靴'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'shop',
      value: 'yes',
      label: 'General Shop (Unspecified)',
      category: 'Shop',
      keywords: ['shop', 'store', 'retail', 'storefront', 'facade', 'boutique'],
      typicalDistanceMeters: 8.0,
    ),

    // --- TOURISM & HISTORIC ---
    OsmTagEntry(
      key: 'tourism',
      value: 'information',
      label: 'Tourist / Trail Information',
      category: 'Tourism',
      keywords: ['info', 'sign', 'signage', 'guidepost', 'board', 'map', '看板', '案内', '登山'],
      typicalDistanceMeters: 3.5,
    ),
    OsmTagEntry(
      key: 'information',
      value: 'guidepost',
      label: 'Directional Guidepost / Trail Sign',
      category: 'Tourism',
      keywords: ['guidepost', 'signpost', 'arrow', 'trail', 'hiking', 'direction', '道標', 'sign'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'information',
      value: 'board',
      label: 'Information Board',
      category: 'Tourism',
      keywords: ['board', 'notice', 'placard', 'panel', 'sign', '案内板'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'information',
      value: 'map',
      label: 'Trail / Park Map Board',
      category: 'Tourism',
      keywords: ['map', 'diagram', 'trail map', '地図', '案内図'],
      typicalDistanceMeters: 2.5,
    ),
    OsmTagEntry(
      key: 'tourism',
      value: 'viewpoint',
      label: 'Scenic Viewpoint',
      category: 'Tourism',
      keywords: ['view', 'panorama', 'mountain', 'valley', 'lookout', '展望', 'landscape', 'sky', 'horizon'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'tourism',
      value: 'artwork',
      label: 'Public Artwork / Statue / Mural',
      category: 'Tourism',
      keywords: ['art', 'statue', 'sculpture', 'mural', 'carving'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'tourism',
      value: 'museum',
      label: 'Museum / Gallery',
      category: 'Tourism',
      keywords: ['museum', 'gallery', 'exhibit', '博物館', '美術館'],
      typicalDistanceMeters: 14.0,
    ),
    OsmTagEntry(
      key: 'tourism',
      value: 'attraction',
      label: 'Tourist Attraction',
      category: 'Tourism',
      keywords: ['attraction', 'landmark', 'sight', 'famous'],
      typicalDistanceMeters: 12.0,
    ),
    OsmTagEntry(
      key: 'tourism',
      value: 'picnic_site',
      label: 'Picnic Area',
      category: 'Tourism',
      keywords: ['picnic', 'table', 'park', 'meadow', 'lunch'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'tourism',
      value: 'camp_site',
      label: 'Camp Site',
      category: 'Tourism',
      keywords: ['camp', 'tent', 'camping', 'キャンプ'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'tourism',
      value: 'alpine_hut',
      label: 'Mountain / Alpine Hut',
      category: 'Tourism',
      keywords: ['hut', 'lodge', 'mountain', '山小屋', 'cabin'],
      typicalDistanceMeters: 12.0,
    ),
    OsmTagEntry(
      key: 'tourism',
      value: 'hotel',
      label: 'Hotel / Inn / Ryokan',
      category: 'Tourism',
      keywords: ['hotel', 'inn', 'ryokan', '旅館', 'ホテル'],
      typicalDistanceMeters: 14.0,
    ),
    OsmTagEntry(
      key: 'historic',
      value: 'monument',
      label: 'Historic Monument',
      category: 'Tourism',
      keywords: ['monument', 'memorial', 'stone', 'pillar', 'historic', '記念碑'],
      typicalDistanceMeters: 6.0,
    ),
    OsmTagEntry(
      key: 'historic',
      value: 'memorial',
      label: 'Memorial / Plaque',
      category: 'Tourism',
      keywords: ['memorial', 'plaque', 'stone', '碑'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'historic',
      value: 'wayside_shrine',
      label: 'Wayside Shrine / Jizo',
      category: 'Tourism',
      keywords: ['shrine', 'jizo', '地蔵', '祠', 'wayside', 'stone'],
      typicalDistanceMeters: 3.5,
    ),
    OsmTagEntry(
      key: 'historic',
      value: 'castle',
      label: 'Castle / Fortress',
      category: 'Tourism',
      keywords: ['castle', 'fort', '城', 'chateau'],
      typicalDistanceMeters: 25.0,
    ),
    OsmTagEntry(
      key: 'historic',
      value: 'ruins',
      label: 'Historic Ruins',
      category: 'Tourism',
      keywords: ['ruins', 'ancient', 'wall', 'stone', '遺跡'],
      typicalDistanceMeters: 12.0,
    ),

    // --- HIGHWAY & TRANSPORT ---
    OsmTagEntry(
      key: 'highway',
      value: 'bus_stop',
      label: 'Bus Stop',
      category: 'Highway',
      keywords: ['bus', 'stop', 'transit', 'バス', 'バス停', 'timetable', 'pole'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'highway',
      value: 'crossing',
      label: 'Pedestrian Crossing / Crosswalk',
      category: 'Highway',
      keywords: ['crossing', 'crosswalk', 'zebra', 'street', 'pedestrian', '横断歩道'],
      typicalDistanceMeters: 6.0,
    ),
    OsmTagEntry(
      key: 'highway',
      value: 'traffic_signals',
      label: 'Traffic Light / Signal',
      category: 'Highway',
      keywords: ['traffic', 'light', 'signal', 'intersection', '信号'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'highway',
      value: 'steps',
      label: 'Stairs / Steps',
      category: 'Highway',
      keywords: ['steps', 'stairs', 'staircase', '階段', 'handrail'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'highway',
      value: 'trailhead',
      label: 'Trailhead',
      category: 'Highway',
      keywords: ['trailhead', 'entrance', 'hiking', '登山口', 'trail'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'highway',
      value: 'street_lamp',
      label: 'Street Lamp',
      category: 'Highway',
      keywords: ['lamp', 'light', 'pole', 'street'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'highway',
      value: 'milestone',
      label: 'Distance Marker / Milestone',
      category: 'Highway',
      keywords: ['milestone', 'marker', 'km', 'post', 'distance'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'highway',
      value: 'footway',
      label: 'Footway / Park Walk',
      category: 'Highway',
      keywords: ['footway', 'sidewalk', 'walkway', 'pavement', 'park', 'walk'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'highway',
      value: 'path',
      label: 'Path / Trail',
      category: 'Highway',
      keywords: ['path', 'trail', 'hiking', 'forest', 'dirt', 'woods'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'highway',
      value: 'cycleway',
      label: 'Cycleway / Bike Path',
      category: 'Highway',
      keywords: ['bike', 'cycle', 'lane', 'cycling'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'railway',
      value: 'subway_entrance',
      label: 'Subway / Metro Entrance',
      category: 'Highway',
      keywords: ['subway', 'metro', 'underground', 'station', '出口', '地下鉄', '駅'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'railway',
      value: 'station',
      label: 'Train Station',
      category: 'Highway',
      keywords: ['train', 'station', 'rail', '駅', 'gare'],
      typicalDistanceMeters: 18.0,
    ),
    OsmTagEntry(
      key: 'public_transport',
      value: 'platform',
      label: 'Public Transport Platform',
      category: 'Highway',
      keywords: ['platform', 'bus', 'tram', 'train', 'stop'],
      typicalDistanceMeters: 5.0,
    ),

    // --- LEISURE & NATURE ---
    OsmTagEntry(
      key: 'leisure',
      value: 'park',
      label: 'Park',
      category: 'Nature',
      keywords: ['park', 'lawn', 'grass', 'tree', 'garden', '公園', 'parc'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'leisure',
      value: 'garden',
      label: 'Garden / Botanical Garden',
      category: 'Nature',
      keywords: ['garden', 'flower', 'botanical', '庭園', 'jardin'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'leisure',
      value: 'playground',
      label: 'Children Playground',
      category: 'Nature',
      keywords: ['playground', 'slide', 'swing', 'kids', 'park'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'leisure',
      value: 'picnic_table',
      label: 'Picnic Table',
      category: 'Nature',
      keywords: ['picnic', 'table', 'bench', 'wood', 'park'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'leisure',
      value: 'fitness_station',
      label: 'Outdoor Fitness Equipment',
      category: 'Nature',
      keywords: ['fitness', 'exercise', 'gym', 'pullup', 'monkey bars', 'park'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'fitness_station',
      value: 'horizontal_ladder',
      label: 'Fitness Horizontal Ladder (Monkey Bars)',
      category: 'Nature',
      keywords: ['monkey bars', 'horizontal ladder', 'fitness', 'exercise', 'bars', '雲梯'],
      typicalDistanceMeters: 4.0,
      description: 'Overhead horizontal ladder / monkey bars at a fitness station',
    ),
    OsmTagEntry(
      key: 'fitness_station',
      value: 'horizontal_bar',
      label: 'Fitness Pull-Up / Horizontal Bar',
      category: 'Nature',
      keywords: ['pull up', 'chin up', 'horizontal bar', 'fitness', 'exercise', '鉄棒'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'fitness_station',
      value: 'parallel_bars',
      label: 'Fitness Parallel Bars',
      category: 'Nature',
      keywords: ['parallel bars', 'dip', 'fitness', 'calisthenics', 'exercise'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'fitness_station',
      value: 'sit-up',
      label: 'Fitness Sit-Up Bench',
      category: 'Nature',
      keywords: ['sit up', 'bench', 'abs', 'fitness', 'exercise'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'fitness_station',
      value: 'balance_beam',
      label: 'Fitness Balance Beam',
      category: 'Nature',
      keywords: ['balance', 'beam', 'fitness', 'exercise'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'fitness_station',
      value: 'rings',
      label: 'Fitness Gymnastic Rings',
      category: 'Nature',
      keywords: ['rings', 'gymnastic', 'calisthenics', 'fitness'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'playground',
      value: 'monkey_bars',
      label: 'Playground Monkey Bars',
      category: 'Nature',
      keywords: ['monkey bars', 'playground', 'kids', 'bars', 'park', '雲梯', 'うんてい'],
      typicalDistanceMeters: 4.0,
      description: 'Overhead monkey bars in a children playground',
    ),
    OsmTagEntry(
      key: 'playground',
      value: 'horizontal_bar',
      label: 'Playground Horizontal Bar',
      category: 'Nature',
      keywords: ['horizontal bar', 'playground', 'kids', 'bar', '鉄棒'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'playground',
      value: 'climbingframe',
      label: 'Playground Climbing Frame',
      category: 'Nature',
      keywords: ['climbing', 'jungle gym', 'playground', 'kids', 'ジャングルジム'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'playground',
      value: 'slide',
      label: 'Playground Slide',
      category: 'Nature',
      keywords: ['slide', 'playground', 'kids', 'すべり台'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'playground',
      value: 'swing',
      label: 'Playground Swing',
      category: 'Nature',
      keywords: ['swing', 'playground', 'kids', 'ブランコ'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'playground',
      value: 'seesaw',
      label: 'Playground Seesaw',
      category: 'Nature',
      keywords: ['seesaw', 'teeter', 'playground', 'kids', 'シーソー'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'playground',
      value: 'sandpit',
      label: 'Playground Sandpit / Sandbox',
      category: 'Nature',
      keywords: ['sandpit', 'sandbox', 'sand', 'playground', 'kids', '砂場'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'leisure',
      value: 'dog_park',
      label: 'Dog Park',
      category: 'Nature',
      keywords: ['dog', 'pet', 'park', 'fence'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'natural',
      value: 'peak',
      label: 'Mountain Peak / Summit',
      category: 'Nature',
      keywords: ['peak', 'summit', 'mountain', 'top', '山頂', '山'],
      typicalDistanceMeters: 8.0,
    ),
    OsmTagEntry(
      key: 'natural',
      value: 'waterfall',
      label: 'Waterfall',
      category: 'Nature',
      keywords: ['waterfall', 'cascade', 'stream', 'water', '滝'],
      typicalDistanceMeters: 18.0,
    ),
    OsmTagEntry(
      key: 'natural',
      value: 'spring',
      label: 'Natural Water Spring',
      category: 'Nature',
      keywords: ['spring', 'water', 'stream', '湧水'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'natural',
      value: 'tree',
      label: 'Notable / Landmark Tree',
      category: 'Nature',
      keywords: ['tree', 'oak', 'cedar', 'sakura', 'cherry', 'plant', 'forest', '木'],
      typicalDistanceMeters: 7.0,
    ),
    OsmTagEntry(
      key: 'natural',
      value: 'cliff',
      label: 'Cliff / Rock Face',
      category: 'Nature',
      keywords: ['cliff', 'rock', 'crag', 'steep'],
      typicalDistanceMeters: 20.0,
    ),
    OsmTagEntry(
      key: 'natural',
      value: 'cave_entrance',
      label: 'Cave Entrance',
      category: 'Nature',
      keywords: ['cave', 'grotto', 'cavern', '洞窟'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'natural',
      value: 'water',
      label: 'Pond / Lake / Stream',
      category: 'Nature',
      keywords: ['pond', 'lake', 'river', 'water', '池', '湖'],
      typicalDistanceMeters: 15.0,
    ),

    // --- SURFACES ---
    OsmTagEntry(
      key: 'surface',
      value: 'asphalt',
      label: 'Surface: Asphalt',
      category: 'Surface',
      keywords: ['asphalt', 'tarmac', 'road', 'paved', 'blacktop'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'surface',
      value: 'paved',
      label: 'Surface: Paved',
      category: 'Surface',
      keywords: ['paved', 'sidewalk', 'street'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'surface',
      value: 'paving_stones',
      label: 'Surface: Paving Stones / Bricks',
      category: 'Surface',
      keywords: ['brick', 'stone', 'paving', 'tile', 'plaza'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'surface',
      value: 'compacted',
      label: 'Surface: Compacted (Park Path)',
      category: 'Surface',
      keywords: ['compacted', 'park', 'path', 'crushed'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'surface',
      value: 'gravel',
      label: 'Surface: Gravel',
      category: 'Surface',
      keywords: ['gravel', 'pebble', 'stones', 'trail'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'surface',
      value: 'ground',
      label: 'Surface: Natural Ground / Dirt',
      category: 'Surface',
      keywords: ['dirt', 'ground', 'soil', 'earth', 'trail', 'hiking', 'forest'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'surface',
      value: 'wood',
      label: 'Surface: Wood / Boardwalk',
      category: 'Surface',
      keywords: ['wood', 'boardwalk', 'plank', 'bridge', 'stairs'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'surface',
      value: 'rock',
      label: 'Surface: Rock / Stone',
      category: 'Surface',
      keywords: ['rock', 'stone', 'boulder', 'mountain'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'surface',
      value: 'grass',
      label: 'Surface: Grass',
      category: 'Surface',
      keywords: ['grass', 'meadow', 'lawn', 'field'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'surface',
      value: 'sand',
      label: 'Surface: Sand',
      category: 'Surface',
      keywords: ['sand', 'beach', 'dune'],
      typicalDistanceMeters: 3.0,
    ),

    // --- ACCESSIBILITY ---
    OsmTagEntry(
      key: 'wheelchair',
      value: 'yes',
      label: 'Wheelchair Accessible (Yes)',
      category: 'Accessibility',
      keywords: ['wheelchair', 'accessible', 'ramp', 'flat', 'step-free'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'wheelchair',
      value: 'limited',
      label: 'Wheelchair Accessible (Limited)',
      category: 'Accessibility',
      keywords: ['wheelchair', 'limited', 'small step'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'wheelchair',
      value: 'no',
      label: 'Wheelchair Accessible (No)',
      category: 'Accessibility',
      keywords: ['wheelchair', 'stairs', 'steps', 'steep'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'tactile_paving',
      value: 'yes',
      label: 'Tactile Paving Present',
      category: 'Accessibility',
      keywords: ['tactile', 'braille', 'yellow blocks', 'crossing', '点字ブロック'],
      typicalDistanceMeters: 3.0,
    ),
    OsmTagEntry(
      key: 'handrail',
      value: 'yes',
      label: 'Handrail Present',
      category: 'Accessibility',
      keywords: ['handrail', 'railing', 'stairs', 'steps', 'ramp'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'lit',
      value: 'yes',
      label: 'Lit at Night (Yes)',
      category: 'Accessibility',
      keywords: ['lit', 'lamp', 'light', 'night', 'street'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'lit',
      value: 'no',
      label: 'Unlit at Night (No)',
      category: 'Accessibility',
      keywords: ['dark', 'unlit', 'forest', 'trail'],
      typicalDistanceMeters: 5.0,
    ),

    // --- ATTRIBUTES & DETAILS ---
    OsmTagEntry(
      key: 'outdoor_seating',
      value: 'yes',
      label: 'Outdoor Seating / Terrace',
      category: 'Attributes',
      keywords: ['terrace', 'patio', 'outdoor', 'cafe', 'restaurant', 'table', 'chair'],
      typicalDistanceMeters: 6.0,
    ),
    OsmTagEntry(
      key: 'takeaway',
      value: 'yes',
      label: 'Takeaway Available',
      category: 'Attributes',
      keywords: ['takeaway', 'to-go', 'takeout', 'cafe', 'bakery', 'fast_food'],
      typicalDistanceMeters: 7.0,
    ),
    OsmTagEntry(
      key: 'covered',
      value: 'yes',
      label: 'Covered / Roofed',
      category: 'Attributes',
      keywords: ['roof', 'covered', 'arcade', 'shelter', 'awning'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'fee',
      value: 'no',
      label: 'Free of Charge (fee=no)',
      category: 'Attributes',
      keywords: ['free', 'public', 'toilets', 'parking', 'park'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'fee',
      value: 'yes',
      label: 'Paid / Fee Required (fee=yes)',
      category: 'Attributes',
      keywords: ['paid', 'ticket', 'fee', 'entrance', 'parking'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'hiking',
      value: 'yes',
      label: 'Hiking Feature / Route',
      category: 'Attributes',
      keywords: ['hiking', 'trail', 'mountain', 'guidepost', '登山'],
      typicalDistanceMeters: 4.0,
    ),
    OsmTagEntry(
      key: 'internet_access',
      value: 'wlan',
      label: 'Wi-Fi Available',
      category: 'Attributes',
      keywords: ['wifi', 'wlan', 'internet', 'cafe', 'library'],
      typicalDistanceMeters: 7.0,
    ),
    OsmTagEntry(
      key: 'dog',
      value: 'leashed',
      label: 'Dogs Allowed (Leashed)',
      category: 'Attributes',
      keywords: ['dog', 'pet', 'park', 'trail'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'religion',
      value: 'shinto',
      label: 'Religion: Shinto',
      category: 'Attributes',
      keywords: ['shinto', 'shrine', 'torii', '神社', '鳥居'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'religion',
      value: 'buddhist',
      label: 'Religion: Buddhist',
      category: 'Attributes',
      keywords: ['buddhist', 'temple', '寺', 'pagoda'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'religion',
      value: 'christian',
      label: 'Religion: Christian',
      category: 'Attributes',
      keywords: ['church', 'christian', 'cathedral', 'cross', 'chapel'],
      typicalDistanceMeters: 12.0,
    ),
    OsmTagEntry(
      key: 'opening_hours',
      value: 'Mo-Su 09:00-18:00',
      label: 'Opening Hours (Days & Hours)',
      category: 'Attributes',
      keywords: ['hours', 'open', 'closed', 'day off', 'schedule', 'shop', 'cafe', 'restaurant', '営業', '定休'],
      description: 'Use 2-letter OSM days before hours (Mo-Fr, Tu-Su) and "off" for closed days — never use deprecated day_off.',
      requiresCustomValue: true,
      suggestedValues: [
        '24/7',
        'Mo-Fr 09:00-18:00',
        'Tu-Su 09:00-18:00',
        'Mo-Sa 09:00-20:00; Su off',
        'Mo,Tu,Th-Su 09:30-18:00; We off',
        'Mo-Fr 09:00-18:00; Sa 10:00-16:00; Su,PH off',
        'Mo-Su 09:00-21:00',
      ],
    ),
    OsmTagEntry(
      key: 'cuisine',
      value: 'coffee_shop',
      label: 'Cuisine Type',
      category: 'Attributes',
      keywords: ['cuisine', 'food', 'restaurant', 'cafe', 'ramen', 'sushi', 'italian', 'french'],
      requiresCustomValue: true,
      suggestedValues: [
        'coffee_shop',
        'japanese',
        'ramen',
        'sushi',
        'french',
        'italian',
        'bakery',
        'pizza',
        'burger',
        'chinese',
        'korean',
        'indian',
        'thai',
        'vegetarian',
      ],
    ),
    OsmTagEntry(
      key: 'brand',
      value: '',
      label: 'Brand / Chain Name',
      category: 'Attributes',
      keywords: ['brand', 'chain', 'shop', 'convenience', 'cafe'],
      requiresCustomValue: true,
      suggestedValues: [
        '7-Eleven',
        'FamilyMart',
        'Lawson',
        'Starbucks',
        'McDonald\'s',
      ],
    ),
    OsmTagEntry(
      key: 'step_count',
      value: '10',
      label: 'Number of Steps',
      category: 'Attributes',
      keywords: ['steps', 'stairs', 'count'],
      requiresCustomValue: true,
      suggestedValues: ['5', '10', '15', '20', '30', '50', '100'],
    ),

    // --- BUILDING, BARRIER & MAN-MADE ---
    OsmTagEntry(
      key: 'building',
      value: 'yes',
      label: 'Building (General)',
      category: 'Building',
      keywords: ['building', 'house', 'facade', 'architecture', 'roof', 'structure'],
      typicalDistanceMeters: 12.0,
    ),
    OsmTagEntry(
      key: 'building',
      value: 'commercial',
      label: 'Commercial Building',
      category: 'Building',
      keywords: ['commercial', 'office', 'mall', 'shop', 'building'],
      typicalDistanceMeters: 14.0,
    ),
    OsmTagEntry(
      key: 'building',
      value: 'shrine',
      label: 'Shrine Building',
      category: 'Building',
      keywords: ['shrine', 'torii', '神社'],
      typicalDistanceMeters: 12.0,
    ),
    OsmTagEntry(
      key: 'building',
      value: 'temple',
      label: 'Temple Building',
      category: 'Building',
      keywords: ['temple', '寺', 'pagoda'],
      typicalDistanceMeters: 14.0,
    ),
    OsmTagEntry(
      key: 'man_made',
      value: 'bridge',
      label: 'Bridge / Footbridge',
      category: 'Building',
      keywords: ['bridge', 'footbridge', 'river', 'crossing', '橋'],
      typicalDistanceMeters: 10.0,
    ),
    OsmTagEntry(
      key: 'man_made',
      value: 'tower',
      label: 'Tower / Observation Tower',
      category: 'Building',
      keywords: ['tower', 'lookout', 'observation', 'タワー', '展望台'],
      typicalDistanceMeters: 22.0,
    ),
    OsmTagEntry(
      key: 'man_made',
      value: 'cairn',
      label: 'Trail Cairn (Stone Pile)',
      category: 'Building',
      keywords: ['cairn', 'stones', 'pile', 'trail', 'mountain', 'marker'],
      typicalDistanceMeters: 3.5,
    ),
    OsmTagEntry(
      key: 'man_made',
      value: 'survey_point',
      label: 'Triangulation / Survey Point',
      category: 'Building',
      keywords: ['survey', 'trig', 'summit', 'benchmark', '三角点'],
      typicalDistanceMeters: 2.5,
    ),
    OsmTagEntry(
      key: 'barrier',
      value: 'gate',
      label: 'Gate / Trail Gate',
      category: 'Building',
      keywords: ['gate', 'fence', 'entrance', 'barrier', '門'],
      typicalDistanceMeters: 5.0,
    ),
    OsmTagEntry(
      key: 'barrier',
      value: 'bollard',
      label: 'Bollard / Vehicle Post',
      category: 'Building',
      keywords: ['bollard', 'post', 'barrier', 'pole'],
      typicalDistanceMeters: 3.5,
    ),
    OsmTagEntry(
      key: 'barrier',
      value: 'stile',
      label: 'Trail Stile',
      category: 'Building',
      keywords: ['stile', 'fence', 'step', 'trail'],
      typicalDistanceMeters: 3.5,
    ),
  ];

  /// Co-occurrence boost map: if record already has key=value (or key=*),
  /// boost complementary tags that commonly belong together on the same feature.
  static const Map<String, List<String>> _coOccurrenceBoosts = {
    'amenity=cafe': [
      'outdoor_seating=yes',
      'takeaway=yes',
      'internet_access=wlan',
      'wheelchair=yes',
      'cuisine=coffee_shop',
      'opening_hours=Mo-Su 09:00-18:00',
    ],
    'amenity=restaurant': [
      'cuisine=coffee_shop',
      'takeaway=yes',
      'outdoor_seating=yes',
      'wheelchair=yes',
      'opening_hours=Mo-Su 09:00-18:00',
    ],
    'shop=bakery': [
      'takeaway=yes',
      'opening_hours=Mo-Su 09:00-18:00',
      'wheelchair=yes',
    ],
    'shop=convenience': [
      'opening_hours=Mo-Su 09:00-18:00',
      'brand=',
      'wheelchair=yes',
      'amenity=atm',
    ],
    'tourism=information': [
      'information=guidepost',
      'information=board',
      'information=map',
      'hiking=yes',
    ],
    'amenity=place_of_worship': [
      'religion=shinto',
      'religion=buddhist',
      'religion=christian',
      'building=shrine',
      'building=temple',
    ],
    'highway=steps': [
      'handrail=yes',
      'step_count=10',
      'surface=rock',
      'surface=wood',
      'lit=yes',
      'wheelchair=no',
    ],
    'highway=bus_stop': [
      'public_transport=platform',
      'amenity=bench',
      'amenity=shelter',
      'tactile_paving=yes',
      'lit=yes',
    ],
    'amenity=toilets': [
      'wheelchair=yes',
      'fee=no',
      'fee=yes',
    ],
    'leisure=park': [
      'amenity=bench',
      'amenity=drinking_water',
      'leisure=playground',
      'dog=leashed',
      'surface=compacted',
    ],
  };

  /// Ranks ALL OSM catalog tags by probability of matching [record] (its AI
  /// candidate scores, detected visual labels, OCR/summary/notes keywords,
  /// existing tags co-occurrence, and trail context), optionally filtered by
  /// [category] and [query].
  static List<RankedOsmTag> rankForRecord(
    OsmRecord record, {
    String? query,
    String category = 'All',
  }) {
    final normalizedQuery = query?.trim().toLowerCase() ?? '';
    final haystack = [
      record.summary,
      record.notes,
      ...record.detectedLabels,
      ...record.tags.keys,
      ...record.tags.values,
    ].join(' ').toLowerCase();

    final isOnTrail = record.trailId != null;

    // Collect co-occurrence boosted tags from current record tags
    final coBoosted = <String>{};
    for (final entry in record.tags.entries) {
      final pair = '${entry.key}=${entry.value}';
      final boosts = _coOccurrenceBoosts[pair];
      if (boosts != null) {
        coBoosted.addAll(boosts);
      }
    }

    final ranked = <RankedOsmTag>[];

    for (final entry in entries) {
      if (category != 'All' && entry.category != category) continue;

      // Search filter
      if (normalizedQuery.isNotEmpty) {
        final searchable =
            '${entry.key} ${entry.value} ${entry.label} ${entry.category} ${entry.description} ${entry.keywords.join(' ')}'
                .toLowerCase();
        final tokens =
            normalizedQuery.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
        if (!tokens.every(searchable.contains)) continue;
      }

      double score = 0.08;
      final reasons = <String>[];

      // 1. Direct AI / Vision candidate probability (highest authority!)
      final directCandidate = record.tagCandidates[entry.tagString] ??
          record.tagCandidates['${entry.key}=*'];
      if (directCandidate != null) {
        score = score > directCandidate ? score : directCandidate;
        reasons.add('Visual AI match');
      }

      // 2. Exact match with already-present tag (shows clearly at top if reviewing)
      if (record.tags[entry.key] == entry.value && entry.value.isNotEmpty) {
        score = score < 0.72 ? 0.72 : score;
        reasons.add('Already on record');
      }

      // 3. Co-occurrence boost with record's primary tags
      if (coBoosted.contains(entry.tagString)) {
        score += 0.42;
        reasons.add('Pairs with ${record.primaryCategoryTag}');
      }

      // 4. Keyword overlap with image labels, summary, OCR, and notes
      int keywordHits = 0;
      for (final kw in entry.keywords) {
        if (kw.length >= 2 && haystack.contains(kw.toLowerCase())) {
          keywordHits++;
        }
      }
      if (keywordHits > 0) {
        score += (0.28 + (keywordHits - 1) * 0.14).clamp(0.0, 0.62);
        reasons.add('Matches picture cues');
      }

      // 5. Key/value word overlap in summary/labels
      if (entry.value.length >= 3 &&
          haystack.contains(entry.value.replaceAll('_', ' '))) {
        score += 0.25;
        if (!reasons.contains('Matches picture cues')) {
          reasons.add('Matches description');
        }
      }

      // 6. Trail vs Urban context prior
      if (isOnTrail) {
        if (entry.category == 'Nature' ||
            entry.category == 'Surface' ||
            entry.key == 'information' ||
            entry.value == 'viewpoint' ||
            entry.value == 'bench' ||
            entry.value == 'drinking_water' ||
            entry.value == 'shelter' ||
            entry.value == 'steps' ||
            entry.value == 'trailhead' ||
            entry.key == 'hiking') {
          score += 0.12;
          if (reasons.isEmpty) reasons.add('Common along trails');
        }
      } else {
        if (entry.category == 'Shop' ||
            entry.category == 'Amenity' ||
            entry.category == 'Accessibility') {
          score += 0.05;
        }
      }

      // 7. Search exact match bonus
      if (normalizedQuery.isNotEmpty) {
        if (entry.value.toLowerCase() == normalizedQuery ||
            entry.key.toLowerCase() == normalizedQuery ||
            entry.label.toLowerCase().startsWith(normalizedQuery)) {
          score += 0.18;
        }
      }

      ranked.add(
        RankedOsmTag(
          entry: entry,
          probability: score.clamp(0.05, 0.99),
          matchReason: reasons.isNotEmpty ? reasons.first : entry.category,
        ),
      );
    }

    ranked.sort((a, b) {
      final cmp = b.probability.compareTo(a.probability);
      if (cmp != 0) return cmp;
      return a.entry.label.compareTo(b.entry.label);
    });
    return ranked;
  }

  static final Set<String> knownKeys = {
    for (final e in entries) e.key,
    'highway',
    'surface',
    'smoothness',
    'sac_scale',
    'trail_visibility',
  };

  static final Set<String> knownTagPairs = {
    for (final e in entries)
      if (!e.requiresCustomValue && e.value.isNotEmpty) '${e.key}=${e.value}',
    for (final h in allHighwayValues) 'highway=${h.$1}',
    for (final s in allSurfaceValues) 'surface=${s.$1}',
    for (final sm in allSmoothnessValues) 'smoothness=${sm.$1}',
    for (final sc in allSacScaleValues) 'sac_scale=${sc.$1}',
    for (final tv in allTrailVisibilityValues) 'trail_visibility=${tv.$1}',
  };
}
