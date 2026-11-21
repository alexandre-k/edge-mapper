import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/hike_trail.dart';
import '../models/mapping_bounty.dart';
import '../models/osm_record.dart';
import 'local_storage_backend.dart';

LocalStorageBackend createBackend() => _SqliteStorageBackend();

class _SqliteStorageBackend implements LocalStorageBackend {
  Database? _db;

  @override
  Future<void> init() async {
    if (_db != null) return;
    final databasesPath = await getDatabasesPath();
    final dbPath = p.join(databasesPath, 'edge_mapper.db');

    _db = await openDatabase(
      dbPath,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE osm_records (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            photo_path TEXT,
            photo_paths_json TEXT NOT NULL DEFAULT '[]',
            photo_locations_json TEXT NOT NULL DEFAULT '[]',
            primary_location_photo_index INTEGER NOT NULL DEFAULT 0,
            is_manual_pin_override INTEGER NOT NULL DEFAULT 0,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            accuracy_meters REAL,
            altitude_meters REAL,
            heading_degrees REAL,
            extrapolated_lat REAL,
            extrapolated_lon REAL,
            estimated_offset_meters REAL NOT NULL DEFAULT 6.0,
            distance_reasoning TEXT NOT NULL DEFAULT '',
            osm_type TEXT NOT NULL DEFAULT 'node',
            summary TEXT NOT NULL,
            detected_language TEXT NOT NULL DEFAULT 'en',
            tags_json TEXT NOT NULL,
            detected_labels_json TEXT NOT NULL DEFAULT '[]',
            tag_candidates_json TEXT NOT NULL DEFAULT '{}',
            ai_source TEXT NOT NULL,
            status TEXT NOT NULL,
            trail_id TEXT,
            notes TEXT NOT NULL DEFAULT '',
            firebase_synced_at TEXT,
            location_proof_json TEXT,
            local_proof_salt TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE hike_trails (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            is_active INTEGER NOT NULL DEFAULT 0,
            activity_type TEXT NOT NULL DEFAULT 'hiking',
            tags_json TEXT NOT NULL,
            needs_location_guess INTEGER NOT NULL DEFAULT 0,
            location_context TEXT NOT NULL DEFAULT '',
            firebase_synced_at TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE trail_points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trail_id TEXT NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            altitude_meters REAL,
            accuracy_meters REAL,
            recorded_at TEXT NOT NULL,
            FOREIGN KEY (trail_id) REFERENCES hike_trails(id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE app_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE mapping_bounties (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            area_label TEXT NOT NULL DEFAULT '',
            target_lat REAL NOT NULL,
            target_lon REAL NOT NULL,
            radius_meters REAL NOT NULL DEFAULT 350.0,
            requested_tags_json TEXT NOT NULL DEFAULT '[]',
            reward_sats INTEGER NOT NULL DEFAULT 0,
            creator_explorer_id TEXT NOT NULL DEFAULT '',
            creator_name TEXT NOT NULL DEFAULT 'Explorer',
            created_at TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'open',
            require_proof INTEGER NOT NULL DEFAULT 1,
            submissions_json TEXT NOT NULL DEFAULT '[]'
          )
        ''');

        await db.execute(
          'CREATE INDEX idx_trail_points_trail_id ON trail_points(trail_id)',
        );
        await db.execute(
          'CREATE INDEX idx_osm_records_created_at ON osm_records(created_at DESC)',
        );
        await db.execute(
          'CREATE INDEX idx_osm_records_updated_at ON osm_records(updated_at DESC)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        Future<void> safeAlter(String sql) async {
          try {
            await db.execute(sql);
          } catch (_) {}
        }

        if (oldVersion < 2) {
          await safeAlter(
            "ALTER TABLE osm_records ADD COLUMN distance_reasoning TEXT NOT NULL DEFAULT ''",
          );
          await safeAlter(
            "ALTER TABLE osm_records ADD COLUMN detected_labels_json TEXT NOT NULL DEFAULT '[]'",
          );
          await safeAlter(
            "ALTER TABLE osm_records ADD COLUMN tag_candidates_json TEXT NOT NULL DEFAULT '{}'",
          );
          await safeAlter(
            'ALTER TABLE osm_records ADD COLUMN firebase_synced_at TEXT',
          );

          await safeAlter(
            "ALTER TABLE hike_trails ADD COLUMN activity_type TEXT NOT NULL DEFAULT 'hiking'",
          );
          await safeAlter(
            'ALTER TABLE hike_trails ADD COLUMN needs_location_guess INTEGER NOT NULL DEFAULT 0',
          );
          await safeAlter(
            "ALTER TABLE hike_trails ADD COLUMN location_context TEXT NOT NULL DEFAULT ''",
          );
          await safeAlter(
            'ALTER TABLE hike_trails ADD COLUMN firebase_synced_at TEXT',
          );

          await db.execute('''
            CREATE TABLE IF NOT EXISTS app_settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        }

        if (oldVersion < 3) {
          await safeAlter(
            'ALTER TABLE osm_records ADD COLUMN updated_at TEXT',
          );
          await db.execute(
            "UPDATE osm_records SET updated_at = created_at WHERE updated_at IS NULL OR updated_at = ''",
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_osm_records_updated_at ON osm_records(updated_at DESC)',
          );
        }

        if (oldVersion < 4) {
          await safeAlter(
            "ALTER TABLE osm_records ADD COLUMN photo_paths_json TEXT NOT NULL DEFAULT '[]'",
          );
          await safeAlter(
            'ALTER TABLE osm_records ADD COLUMN location_proof_json TEXT',
          );
          await safeAlter(
            'ALTER TABLE osm_records ADD COLUMN local_proof_salt TEXT',
          );
          await db.execute('''
            CREATE TABLE IF NOT EXISTS mapping_bounties (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              description TEXT NOT NULL DEFAULT '',
              area_label TEXT NOT NULL DEFAULT '',
              target_lat REAL NOT NULL,
              target_lon REAL NOT NULL,
              radius_meters REAL NOT NULL DEFAULT 350.0,
              requested_tags_json TEXT NOT NULL DEFAULT '[]',
              reward_sats INTEGER NOT NULL DEFAULT 0,
              creator_explorer_id TEXT NOT NULL DEFAULT '',
              creator_name TEXT NOT NULL DEFAULT 'Explorer',
              created_at TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'open',
              require_proof INTEGER NOT NULL DEFAULT 1,
              submissions_json TEXT NOT NULL DEFAULT '[]'
            )
          ''');
        }
        if (oldVersion < 5) {
          await safeAlter(
            "ALTER TABLE osm_records ADD COLUMN photo_locations_json TEXT NOT NULL DEFAULT '[]'",
          );
          await safeAlter(
            'ALTER TABLE osm_records ADD COLUMN primary_location_photo_index INTEGER NOT NULL DEFAULT 0',
          );
          await safeAlter(
            'ALTER TABLE osm_records ADD COLUMN is_manual_pin_override INTEGER NOT NULL DEFAULT 0',
          );
        }
      },
    );
  }

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('LocalDbService.init() must be called before use.');
    }
    return db;
  }

  @override
  Future<Map<String, String>> getAllSettings() async {
    final rows = await _database.query('app_settings');
    return {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
  }

  @override
  Future<void> setSetting(String key, String value) async {
    await _database.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteSetting(String key) async {
    await _database.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
    );
  }

  @override
  Future<void> upsertRecord(OsmRecord record) async {
    await _database.insert(
      'osm_records',
      record.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<OsmRecord>> getAllRecords() async {
    final rows = await _database.query(
      'osm_records',
      orderBy: 'COALESCE(updated_at, created_at) DESC, created_at DESC',
    );
    return rows.map(OsmRecord.fromDbMap).toList();
  }

  @override
  Future<List<OsmRecord>> getRecordsForTrail(String trailId) async {
    final rows = await _database.query(
      'osm_records',
      where: 'trail_id = ?',
      whereArgs: [trailId],
      orderBy: 'created_at ASC',
    );
    return rows.map(OsmRecord.fromDbMap).toList();
  }

  @override
  Future<void> deleteRecord(String id) async {
    await _database.delete(
      'osm_records',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> upsertTrail(HikeTrail trail) async {
    await _database.insert(
      'hike_trails',
      trail.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<int> insertTrailPoint(TrailPoint point) async {
    return _database.insert('trail_points', point.toDbMap());
  }

  @override
  Future<void> replaceTrailPoints(
    String trailId,
    List<TrailPoint> points,
  ) async {
    await _database.transaction((txn) async {
      await txn.delete(
        'trail_points',
        where: 'trail_id = ?',
        whereArgs: [trailId],
      );
      for (final pt in points) {
        await txn.insert('trail_points', pt.toDbMap());
      }
    });
  }

  @override
  Future<void> deleteTrailPoint(int pointId) async {
    await _database.delete(
      'trail_points',
      where: 'id = ?',
      whereArgs: [pointId],
    );
  }

  @override
  Future<List<HikeTrail>> getAllTrails() async {
    final trailRows = await _database.query(
      'hike_trails',
      orderBy: 'started_at DESC',
    );
    final result = <HikeTrail>[];
    for (final row in trailRows) {
      final trailId = row['id'] as String;
      final pointRows = await _database.query(
        'trail_points',
        where: 'trail_id = ?',
        whereArgs: [trailId],
        orderBy: 'id ASC',
      );
      final points = pointRows.map(TrailPoint.fromDbMap).toList();
      result.add(HikeTrail.fromDbMap(row, points: points));
    }
    return result;
  }

  @override
  Future<void> deleteTrail(String trailId) async {
    await _database.delete(
      'trail_points',
      where: 'trail_id = ?',
      whereArgs: [trailId],
    );
    await _database.delete(
      'hike_trails',
      where: 'id = ?',
      whereArgs: [trailId],
    );
  }

  @override
  Future<void> upsertBounty(MappingBounty bounty) async {
    await _database.insert(
      'mapping_bounties',
      bounty.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<MappingBounty>> getAllBounties() async {
    final rows = await _database.query(
      'mapping_bounties',
      orderBy: 'created_at DESC',
    );
    return rows.map(MappingBounty.fromDbMap).toList();
  }

  @override
  Future<void> deleteBounty(String id) async {
    await _database.delete(
      'mapping_bounties',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
