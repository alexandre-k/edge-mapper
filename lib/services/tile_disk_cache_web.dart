import 'dart:typed_data';

import 'tile_disk_cache.dart';

TileDiskCache createTileDiskCacheImpl() => _WebTileDiskCache();

/// Lightweight memory tile cache on Web (browsers also cache HTTP tiles natively).
class _WebTileDiskCache implements TileDiskCache {
  final Map<String, Uint8List> _tiles = {};

  String _key(String styleDir, int z, int x, int y) => '$styleDir/$z/$x/$y';

  @override
  Future<void> init() async {}

  @override
  Future<Uint8List?> readTile(String styleDir, int z, int x, int y) async =>
      _tiles[_key(styleDir, z, x, y)];

  @override
  Future<bool> hasTile(String styleDir, int z, int x, int y) async =>
      _tiles.containsKey(_key(styleDir, z, x, y));

  @override
  Future<void> writeTile(
    String styleDir,
    int z,
    int x,
    int y,
    Uint8List bytes,
  ) async {
    if (_tiles.length > 350) {
      _tiles.remove(_tiles.keys.first);
    }
    _tiles[_key(styleDir, z, x, y)] = bytes;
  }

  @override
  Future<(int count, int bytes)> computeStats() async {
    int bytes = 0;
    for (final v in _tiles.values) {
      bytes += v.length;
    }
    return (_tiles.length, bytes);
  }

  @override
  Future<void> clear() async {
    _tiles.clear();
  }
}
