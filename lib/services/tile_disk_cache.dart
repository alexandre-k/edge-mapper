import 'dart:typed_data';

import 'tile_disk_cache_io.dart'
    if (dart.library.js_interop) 'tile_disk_cache_web.dart' as impl;

abstract class TileDiskCache {
  Future<void> init();
  Future<Uint8List?> readTile(String styleDir, int z, int x, int y);
  Future<bool> hasTile(String styleDir, int z, int x, int y);
  Future<void> writeTile(String styleDir, int z, int x, int y, Uint8List bytes);
  Future<(int count, int bytes)> computeStats();
  Future<void> clear();
}

TileDiskCache createTileDiskCache() => impl.createTileDiskCacheImpl();
