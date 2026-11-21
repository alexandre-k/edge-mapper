import '../models/hike_trail.dart';
import '../models/mapping_bounty.dart';
import '../models/osm_record.dart';
import 'local_storage_backend.dart';

/// Offline-first local storage powering Edge Mapper's OSM records, activity
/// routes, mapping bounties, and app settings (SQLite v4 on Android/IO, IndexedDB/localStorage on Web).
class LocalDbService {
  final LocalStorageBackend _backend = createLocalStorageBackend();

  Future<void> init() => _backend.init();

  Future<Map<String, String>> getAllSettings() => _backend.getAllSettings();
  Future<void> setSetting(String key, String value) =>
      _backend.setSetting(key, value);
  Future<void> deleteSetting(String key) => _backend.deleteSetting(key);

  Future<void> upsertRecord(OsmRecord record) => _backend.upsertRecord(record);
  Future<List<OsmRecord>> getAllRecords() => _backend.getAllRecords();
  Future<List<OsmRecord>> getRecordsForTrail(String trailId) =>
      _backend.getRecordsForTrail(trailId);
  Future<void> deleteRecord(String id) => _backend.deleteRecord(id);

  Future<void> upsertTrail(HikeTrail trail) => _backend.upsertTrail(trail);
  Future<int> insertTrailPoint(TrailPoint point) =>
      _backend.insertTrailPoint(point);
  Future<void> replaceTrailPoints(String trailId, List<TrailPoint> points) =>
      _backend.replaceTrailPoints(trailId, points);
  Future<void> deleteTrailPoint(int pointId) =>
      _backend.deleteTrailPoint(pointId);
  Future<List<HikeTrail>> getAllTrails() => _backend.getAllTrails();
  Future<void> deleteTrail(String trailId) => _backend.deleteTrail(trailId);

  Future<void> upsertBounty(MappingBounty bounty) =>
      _backend.upsertBounty(bounty);
  Future<List<MappingBounty>> getAllBounties() => _backend.getAllBounties();
  Future<void> deleteBounty(String id) => _backend.deleteBounty(id);
}
