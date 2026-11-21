import 'dart:convert';
import 'dart:js_interop';

import '../models/hike_trail.dart';
import '../models/mapping_bounty.dart';
import '../models/osm_record.dart';
import 'local_storage_backend.dart';

@JS('window.localStorage.getItem')
external JSString? _lsGetItem(JSString key);

@JS('window.localStorage.setItem')
external void _lsSetItem(JSString key, JSString value);

@JS('window.localStorage.removeItem')
external void _lsRemoveItem(JSString key);

@JS('window.edgeMapperIdb.get')
external JSPromise<JSString> _idbGet(JSString key);

@JS('window.edgeMapperIdb.set')
external JSPromise<JSBoolean> _idbSet(JSString key, JSString value);

LocalStorageBackend createBackend() => _WebStorageBackend();

/// Persistent browser storage backend for Flutter Web on Linux/desktop:
/// stores records (with synced photos) in IndexedDB so Chrome's 5MB
/// localStorage quota never silently drops synced photos, while keeping
/// settings/trails fast and backwards-compatible.
class _WebStorageBackend implements LocalStorageBackend {
  static const _settingsKey = 'edge_mapper_v1_settings';
  static const _recordsKey = 'edge_mapper_v1_records';
  static const _trailsKey = 'edge_mapper_v1_trails';
  static const _pointsKey = 'edge_mapper_v1_points';
  static const _bountiesKey = 'edge_mapper_v1_bounties';

  final Map<String, String> _settings = {};
  final Map<String, Map<String, Object?>> _records = {};
  final Map<String, Map<String, Object?>> _trails = {};
  final List<Map<String, Object?>> _points = [];
  final Map<String, Map<String, Object?>> _bounties = {};
  int _nextPointId = 1;

  String? _readRaw(String key) {
    try {
      return _lsGetItem(key.toJS)?.toDart;
    } catch (_) {
      return null;
    }
  }

  void _writeRaw(String key, String value) {
    try {
      _lsSetItem(key.toJS, value.toJS);
    } catch (_) {}
  }

  Future<String?> _readIdbOrLs(String key) async {
    try {
      final idbVal = (await _idbGet(key.toJS).toDart).toDart;
      if (idbVal.isNotEmpty) return idbVal;
    } catch (_) {}
    final lsVal = _readRaw(key);
    if (lsVal != null && lsVal.isNotEmpty) {
      // One-time migrate existing localStorage records into IndexedDB
      try {
        await _idbSet(key.toJS, lsVal.toJS).toDart;
      } catch (_) {}
      return lsVal;
    }
    return null;
  }

  Future<void> _saveRecordsAsync() async {
    final encoded = jsonEncode(_records.values.toList());
    try {
      await _idbSet(_recordsKey.toJS, encoded.toJS).toDart;
    } catch (_) {}
    // Only mirror to localStorage when small enough to stay safely under Chrome's 5MB cap;
    // remove stale mirror when exceeding the cap so deleted records don't linger.
    if (encoded.length < 2 * 1024 * 1024) {
      _writeRaw(_recordsKey, encoded);
    } else {
      try {
        _lsRemoveItem(_recordsKey.toJS);
      } catch (_) {}
    }
  }

  @override
  Future<void> init() async {
    final rawSettings = _readRaw(_settingsKey);
    if (rawSettings != null && rawSettings.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawSettings) as Map<String, dynamic>;
        _settings.clear();
        decoded.forEach((k, v) => _settings[k] = v.toString());
      } catch (_) {}
    }

    final rawRecords = await _readIdbOrLs(_recordsKey);
    if (rawRecords != null && rawRecords.isNotEmpty) {
      try {
        final list = jsonDecode(rawRecords) as List;
        _records.clear();
        for (final item in list) {
          if (item is Map) {
            final map = Map<String, Object?>.from(item);
            final id = map['id']?.toString();
            if (id != null && id.isNotEmpty) _records[id] = map;
          }
        }
      } catch (_) {}
    }

    final rawTrails = _readRaw(_trailsKey);
    if (rawTrails != null && rawTrails.isNotEmpty) {
      try {
        final list = jsonDecode(rawTrails) as List;
        _trails.clear();
        for (final item in list) {
          if (item is Map) {
            final map = Map<String, Object?>.from(item);
            final id = map['id']?.toString();
            if (id != null && id.isNotEmpty) _trails[id] = map;
          }
        }
      } catch (_) {}
    }

    final rawPoints = _readRaw(_pointsKey);
    if (rawPoints != null && rawPoints.isNotEmpty) {
      try {
        final list = jsonDecode(rawPoints) as List;
        _points.clear();
        for (final item in list) {
          if (item is Map) {
            final map = Map<String, Object?>.from(item);
            _points.add(map);
            final pid = (map['id'] as num?)?.toInt() ?? 0;
            if (pid >= _nextPointId) _nextPointId = pid + 1;
          }
        }
      } catch (_) {}
    }

    final rawBounties = _readRaw(_bountiesKey);
    if (rawBounties != null && rawBounties.isNotEmpty) {
      try {
        final list = jsonDecode(rawBounties) as List;
        _bounties.clear();
        for (final item in list) {
          if (item is Map) {
            final map = Map<String, Object?>.from(item);
            final id = map['id']?.toString();
            if (id != null && id.isNotEmpty) _bounties[id] = map;
          }
        }
      } catch (_) {}
    }
  }

  void _saveSettings() => _writeRaw(_settingsKey, jsonEncode(_settings));
  void _saveTrails() =>
      _writeRaw(_trailsKey, jsonEncode(_trails.values.toList()));
  void _savePoints() => _writeRaw(_pointsKey, jsonEncode(_points));
  void _saveBounties() =>
      _writeRaw(_bountiesKey, jsonEncode(_bounties.values.toList()));

  @override
  Future<Map<String, String>> getAllSettings() async =>
      Map<String, String>.from(_settings);

  @override
  Future<void> setSetting(String key, String value) async {
    _settings[key] = value;
    _saveSettings();
  }

  @override
  Future<void> deleteSetting(String key) async {
    _settings.remove(key);
    _saveSettings();
  }

  @override
  Future<void> upsertRecord(OsmRecord record) async {
    _records[record.id] = record.toDbMap();
    await _saveRecordsAsync();
  }

  @override
  Future<List<OsmRecord>> getAllRecords() async {
    final list = _records.values.map(OsmRecord.fromDbMap).toList();
    list.sort((a, b) {
      final byUpdated = b.updatedAt.compareTo(a.updatedAt);
      if (byUpdated != 0) return byUpdated;
      return b.createdAt.compareTo(a.createdAt);
    });
    return list;
  }

  @override
  Future<List<OsmRecord>> getRecordsForTrail(String trailId) async {
    final list = _records.values
        .map(OsmRecord.fromDbMap)
        .where((r) => r.trailId == trailId)
        .toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  @override
  Future<void> deleteRecord(String id) async {
    _records.remove(id);
    await _saveRecordsAsync();
  }

  @override
  Future<void> upsertTrail(HikeTrail trail) async {
    _trails[trail.id] = trail.toDbMap();
    _saveTrails();
  }

  @override
  Future<int> insertTrailPoint(TrailPoint point) async {
    final id = _nextPointId++;
    final map = Map<String, Object?>.from(point.toDbMap())..['id'] = id;
    _points.add(map);
    _savePoints();
    return id;
  }

  @override
  Future<void> replaceTrailPoints(
    String trailId,
    List<TrailPoint> points,
  ) async {
    _points.removeWhere((p) => p['trail_id'] == trailId);
    for (final pt in points) {
      final id = _nextPointId++;
      final map = Map<String, Object?>.from(pt.toDbMap())..['id'] = id;
      _points.add(map);
    }
    _savePoints();
  }

  @override
  Future<void> deleteTrailPoint(int pointId) async {
    _points.removeWhere((p) => (p['id'] as num?)?.toInt() == pointId);
    _savePoints();
  }

  @override
  Future<List<HikeTrail>> getAllTrails() async {
    final trails = <HikeTrail>[];
    for (final row in _trails.values) {
      final trailId = row['id'] as String;
      final pts = _points
          .where((pt) => pt['trail_id'] == trailId)
          .map(TrailPoint.fromDbMap)
          .toList()
        ..sort((a, b) => (a.id ?? 0).compareTo(b.id ?? 0));
      trails.add(HikeTrail.fromDbMap(row, points: pts));
    }
    trails.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return trails;
  }

  @override
  Future<void> deleteTrail(String trailId) async {
    _points.removeWhere((pt) => pt['trail_id'] == trailId);
    _trails.remove(trailId);
    _savePoints();
    _saveTrails();
  }

  @override
  Future<void> upsertBounty(MappingBounty bounty) async {
    _bounties[bounty.id] = bounty.toDbMap();
    _saveBounties();
  }

  @override
  Future<List<MappingBounty>> getAllBounties() async {
    final list = _bounties.values.map(MappingBounty.fromDbMap).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<void> deleteBounty(String id) async {
    _bounties.remove(id);
    _saveBounties();
  }
}
