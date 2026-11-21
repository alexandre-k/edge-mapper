import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';

@JS('window.edgeMapperPhoto.compressDataUri')
external JSPromise<JSString> _jsCompressDataUri(
  JSString dataUri,
  JSNumber maxRawBytes,
);

final Map<String, Uint8List> _decodedCache = {};

Uint8List? _decodeDataUri(String dataUri) {
  final cached = _decodedCache[dataUri];
  if (cached != null) return cached;
  final comma = dataUri.indexOf(',');
  if (comma < 0) return null;
  try {
    final bytes = base64Decode(dataUri.substring(comma + 1));
    if (_decodedCache.length > 60) _decodedCache.clear();
    _decodedCache[dataUri] = bytes;
    return bytes;
  } catch (_) {
    return null;
  }
}

bool _isAllowedPhotoUrl(String path) {
  if (path.startsWith('data:image/jpeg') ||
      path.startsWith('data:image/png') ||
      path.startsWith('data:image/webp') ||
      path.startsWith('blob:')) {
    return true;
  }
  final uri = Uri.tryParse(path);
  if (uri == null) return false;
  if (uri.scheme == 'https' && uri.host.isNotEmpty) return true;
  if (uri.scheme == 'http' &&
      (uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1')) {
    return true;
  }
  return false;
}

bool photoExistsImpl(String? path) {
  if (path == null || path.isEmpty) return false;
  return _isAllowedPhotoUrl(path);
}

Future<Uint8List?> readPhotoBytesImpl(String? path) async {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('data:')) {
    return _decodeDataUri(path);
  }
  return null;
}

Future<String?> compressPhotoToDataUriImpl(
  String path, {
  required int maxRawBytes,
  required String mimeType,
}) async {
  if (!path.startsWith('data:image/')) return null;
  final maxB64Len = (maxRawBytes * 4 ~/ 3) + 64;
  if (path.length <= maxB64Len) return path;
  try {
    final compressed = (await _jsCompressDataUri(
      path.toJS,
      maxRawBytes.toJS,
    ).toDart)
        .toDart;
    if (compressed.startsWith('data:image/') && compressed.length <= maxB64Len) {
      return compressed;
    }
  } catch (_) {}
  return null;
}

Future<String> persistPickedPhotoImpl(XFile picked, String id) async {
  final bytes = await picked.readAsBytes();
  final mime = picked.mimeType?.isNotEmpty == true
      ? picked.mimeType!
      : (picked.name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg');
  final rawDataUri = 'data:$mime;base64,${base64Encode(bytes)}';
  // Downscale large desktop/phone images immediately so they stay fast for
  // Nano 4, Cloud AI, IndexedDB, and Firestore cross-device sync.
  final compressed = await compressPhotoToDataUriImpl(
    rawDataUri,
    maxRawBytes: 380 * 1024,
    mimeType: mime,
  );
  final finalUri = (compressed != null && compressed.isNotEmpty)
      ? compressed
      : rawDataUri;
  _decodeDataUri(finalUri);
  return finalUri;
}

Future<String?> restorePhotoFromDataUriImpl(
  String dataUri,
  String recordId,
) async {
  if (!dataUri.startsWith('data:image/')) return null;
  _decodeDataUri(dataUri);
  return dataUri;
}

Future<void> deletePersistedPhotoImpl(String? path) async {
  if (path != null) _decodedCache.remove(path);
}

Widget buildPhotoWidgetImpl(
  String path, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
}) {
  if (path.startsWith('data:')) {
    final bytes = _decodeDataUri(path);
    if (bytes != null) {
      return Image.memory(
        bytes,
        width: width,
        height: height,
        fit: fit,
      );
    }
  }
  if (!_isAllowedPhotoUrl(path)) {
    return SizedBox(width: width, height: height);
  }
  return Image.network(
    path,
    width: width,
    height: height,
    fit: fit,
  );
}
