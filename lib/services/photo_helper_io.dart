import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const MethodChannel _photoChannel = MethodChannel('com.edgemapper.app/photo');

bool photoExistsImpl(String? path) =>
    path != null && path.isNotEmpty && File(path).existsSync();

Future<Uint8List?> readPhotoBytesImpl(String? path) async {
  if (path == null || path.isEmpty) return null;
  final file = File(path);
  if (!await file.exists()) return null;
  return file.readAsBytes();
}

Future<String?> compressPhotoToDataUriImpl(
  String path, {
  required int maxRawBytes,
  required String mimeType,
}) async {
  final file = File(path);
  if (!await file.exists()) return null;

  final rawBytes = await file.readAsBytes();
  if (rawBytes.isEmpty) return null;
  if (rawBytes.length <= maxRawBytes) {
    return 'data:$mimeType;base64,${base64Encode(rawBytes)}';
  }

  // Use native Android Bitmap JPEG compressor so full-resolution phone camera
  // photos (600KB - 5MB+) compress cleanly for Firestore sync.
  try {
    final compressed = await _photoChannel.invokeMethod<Uint8List>(
      'compressToJpegBytes',
      {
        'path': path,
        'maxBytes': maxRawBytes,
      },
    );
    if (compressed != null &&
        compressed.isNotEmpty &&
        compressed.length <= maxRawBytes) {
      return 'data:image/jpeg;base64,${base64Encode(compressed)}';
    }
  } catch (e) {
    debugPrint('[EdgeMapper] Native photo compress fallback: $e');
  }
  return null;
}

String _sanitizeFileSegment(String raw, {required String fallback}) {
  final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
  return cleaned.isEmpty ? fallback : cleaned;
}

Future<String> persistPickedPhotoImpl(XFile picked, String id) async {
  final appDir = await getApplicationDocumentsDirectory();
  final photosDir = Directory(p.join(appDir.path, 'snapshots'));
  if (!await photosDir.exists()) {
    await photosDir.create(recursive: true);
  }
  final rawExt = p.extension(picked.path).toLowerCase();
  final ext = (rawExt == '.jpg' ||
          rawExt == '.jpeg' ||
          rawExt == '.png' ||
          rawExt == '.webp')
      ? rawExt
      : '.jpg';
  final safeId = _sanitizeFileSegment(id, fallback: 'photo');
  final destPath = p.join(photosDir.path, '$safeId$ext');
  await File(picked.path).copy(destPath);
  return destPath;
}

Future<String?> restorePhotoFromDataUriImpl(
  String dataUri,
  String recordId,
) async {
  final comma = dataUri.indexOf(',');
  if (comma < 0) return null;
  try {
    final bytes = base64Decode(dataUri.substring(comma + 1));
    if (bytes.isEmpty) return null;
    final appDir = await getApplicationDocumentsDirectory();
    final photosDir = Directory(p.join(appDir.path, 'snapshots'));
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }
    final ext = dataUri.startsWith('data:image/png') ? '.png' : '.jpg';
    final safeId = _sanitizeFileSegment(recordId, fallback: 'record');
    final destPath = p.join(photosDir.path, 'sync_$safeId$ext');
    await File(destPath).writeAsBytes(bytes, flush: true);
    return destPath;
  } catch (_) {
    return null;
  }
}

Future<void> deletePersistedPhotoImpl(String? path) async {
  if (path == null || path.isEmpty) return;
  final file = File(path);
  if (await file.exists()) {
    try {
      await file.delete();
    } catch (_) {}
  }
}

Widget buildPhotoWidgetImpl(
  String path, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
}) {
  return Image.file(
    File(path),
    width: width,
    height: height,
    fit: fit,
  );
}
