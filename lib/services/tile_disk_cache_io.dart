import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tile_disk_cache.dart';

TileDiskCache createTileDiskCacheImpl() => _IoTileDiskCache();

class _IoTileDiskCache implements TileDiskCache {
  Directory? _root;

  @override
  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    // Purge legacy caches (including v3 CARTO Voyager tiles that caused CJK mojibake)
    for (final oldName in const ['osm_tiles', 'osm_tiles_v2', 'osm_tiles_v3']) {
      final legacyDir = Directory(p.join(docs.path, oldName));
      if (await legacyDir.exists()) {
        try {
          await legacyDir.delete(recursive: true);
        } catch (_) {}
      }
    }
    final dir = Directory(p.join(docs.path, 'osm_tiles_v4'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _root = dir;
  }

  File? _fileFor(String styleDir, int z, int x, int y) {
    final root = _root;
    if (root == null) return null;
    return File(p.join(root.path, styleDir, '$z', '$x', '$y.png'));
  }

  @override
  Future<Uint8List?> readTile(String styleDir, int z, int x, int y) async {
    final f = _fileFor(styleDir, z, x, y);
    if (f == null || !await f.exists()) return null;
    try {
      final bytes = await f.readAsBytes();
      return bytes.isNotEmpty ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> hasTile(String styleDir, int z, int x, int y) async {
    final f = _fileFor(styleDir, z, x, y);
    return f != null && await f.exists();
  }

  @override
  Future<void> writeTile(
    String styleDir,
    int z,
    int x,
    int y,
    Uint8List bytes,
  ) async {
    final f = _fileFor(styleDir, z, x, y);
    if (f == null) return;
    if (!await f.parent.exists()) {
      await f.parent.create(recursive: true);
    }
    await f.writeAsBytes(bytes, flush: false);
  }

  @override
  Future<(int count, int bytes)> computeStats() async {
    final root = _root;
    if (root == null || !await root.exists()) return (0, 0);
    int count = 0;
    int bytes = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        count++;
        bytes += await entity.length();
      }
    }
    return (count, bytes);
  }

  @override
  Future<void> clear() async {
    final root = _root;
    if (root != null && await root.exists()) {
      await root.delete(recursive: true);
      await root.create(recursive: true);
    }
  }
}
