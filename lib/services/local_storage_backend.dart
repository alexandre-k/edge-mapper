import '../models/hike_trail.dart';
import '../models/mapping_bounty.dart';
import '../models/osm_record.dart';

import 'local_storage_io.dart'
    if (dart.library.js_interop) 'local_storage_web.dart' as impl;

abstract class LocalStorageBackend {
  Future<void> init();

  Future<Map<String, String>> getAllSettings();
  Future<void> setSetting(String key, String value);
  Future<void> deleteSetting(String key);

  Future<void> upsertRecord(OsmRecord record);
  Future<List<OsmRecord>> getAllRecords();
  Future<List<OsmRecord>> getRecordsForTrail(String trailId);
  Future<void> deleteRecord(String id);

  Future<void> upsertTrail(HikeTrail trail);
  Future<int> insertTrailPoint(TrailPoint point);
  Future<void> replaceTrailPoints(String trailId, List<TrailPoint> points);
  Future<void> deleteTrailPoint(int pointId);
  Future<List<HikeTrail>> getAllTrails();
  Future<void> deleteTrail(String trailId);

  Future<void> upsertBounty(MappingBounty bounty);
  Future<List<MappingBounty>> getAllBounties();
  Future<void> deleteBounty(String id);
}

LocalStorageBackend createLocalStorageBackend() => impl.createBackend();
