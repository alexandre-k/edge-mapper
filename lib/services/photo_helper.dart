import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';

import 'photo_helper_io.dart'
    if (dart.library.js_interop) 'photo_helper_web.dart' as impl;

bool photoExists(String? path) => impl.photoExistsImpl(path);

Future<Uint8List?> readPhotoBytes(String? path) =>
    impl.readPhotoBytesImpl(path);

/// Encodes (and automatically compresses/resizes when larger than [maxRawBytes])
/// a local photo as a JPEG/image data URI so EVERY photo fits comfortably inside
/// Firestore's 1 MiB document cap for cross-device sync.
Future<String?> readPhotoAsDataUri(
  String? path, {
  int maxRawBytes = 420 * 1024,
}) async {
  if (path == null || path.isEmpty) return null;
  return impl.compressPhotoToDataUriImpl(
    path,
    maxRawBytes: maxRawBytes,
    mimeType: mimeTypeForPhoto(path),
  );
}

Future<String?> restorePhotoFromDataUri(String dataUri, String recordId) =>
    impl.restorePhotoFromDataUriImpl(dataUri, recordId);

String mimeTypeForPhoto(String path) {
  if (path.startsWith('data:')) {
    final semi = path.indexOf(';');
    if (semi > 5) return path.substring(5, semi);
  }
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}

Future<String> persistPickedPhoto(XFile picked, String id) =>
    impl.persistPickedPhotoImpl(picked, id);

Future<void> deletePersistedPhoto(String? path) =>
    impl.deletePersistedPhotoImpl(path);

Widget buildPhotoWidget(
  String path, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
}) =>
    impl.buildPhotoWidgetImpl(path, width: width, height: height, fit: fit);
