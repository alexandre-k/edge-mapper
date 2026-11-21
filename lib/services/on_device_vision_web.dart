import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';

import 'on_device_vision.dart';
import 'photo_helper.dart';

@JS('window.edgeMapperNano.checkAvailability')
external JSPromise<JSString> _jsCheckAvailability();

@JS('window.edgeMapperNano.generateOsmDraft')
external JSPromise<JSString> _jsGenerateOsmDraft(
  JSString promptText,
  JSString imageBase64,
  JSString mimeType,
);

@JS('window.edgeMapperNano.getProgress')
external JSString _jsGetProgress();

@JS('window.edgeMapperNano.cancelActive')
external void _jsCancelActive();

@JS('window.edgeMapperNano.testNano')
external JSPromise<JSString> _jsTestNano();

Future<LocalNanoCheckResult> checkLocalNanoAvailabilityImpl() async {
  try {
    final raw = (await _jsCheckAvailability().toDart).toDart;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final available = decoded['available'] == true;
    final reason = decoded['reason']?.toString() ?? '';
    return LocalNanoCheckResult(
      available: available,
      aicoreInstalled: available,
      deviceModel: 'Desktop Web (Gemini Nano 4)',
      sdkInt: 0,
      reason: reason,
    );
  } catch (e) {
    debugPrint('[EdgeMapper] Web Gemini Nano check error: $e');
    return const LocalNanoCheckResult(
      available: false,
      aicoreInstalled: false,
      deviceModel: 'Desktop Web',
      sdkInt: 0,
      reason: 'Enable Chrome Built-in AI (Gemini Nano 4) in chrome://flags.',
    );
  }
}

Future<String?> runLocalNanoDraftImpl({
  required String prompt,
  String? photoPath,
  required double latitude,
  required double longitude,
  double? headingDegrees,
  String? userHint,
  void Function(String step)? onProgress,
}) async {
  onProgress?.call('Preparing photo for Nano 4...');
  String imageB64 = '';
  String mimeType = 'image/jpeg';
  if (photoPath != null && photoPath.isNotEmpty) {
    final bytes = await readPhotoBytes(photoPath);
    if (bytes != null && bytes.isNotEmpty) {
      imageB64 = base64Encode(bytes);
      mimeType = mimeTypeForPhoto(photoPath);
    }
  }

  String lastReported = '';
  final pollTimer = Timer.periodic(const Duration(milliseconds: 350), (_) {
    try {
      final p = _jsGetProgress().toDart;
      if (p.isNotEmpty && p != lastReported) {
        lastReported = p;
        onProgress?.call(p);
      }
    } catch (_) {}
  });

  try {
    final raw = (await _jsGenerateOsmDraft(
      prompt.toJS,
      imageB64.toJS,
      mimeType.toJS,
    ).toDart.timeout(const Duration(seconds: 95)))
        .toDart;

    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    if (decoded['supported'] == true) {
      final jsonText = decoded['json']?.toString();
      if (jsonText != null && jsonText.trim().isNotEmpty) {
        return jsonText;
      }
    }
    final err = decoded['error']?.toString();
    if (err != null && err.trim().isNotEmpty) {
      throw Exception(err.trim());
    }
    return null;
  } finally {
    pollTimer.cancel();
  }
}

void cancelLocalNanoDraftImpl() {
  try {
    _jsCancelActive();
  } catch (_) {}
}

Future<String> testLocalNanoImpl() async {
  try {
    final raw = (await _jsTestNano()
            .toDart
            .timeout(const Duration(seconds: 25)))
        .toDart;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    if (decoded['ok'] == true) {
      final mode = decoded['multimodal'] == true ? 'multimodal' : 'text-only';
      final ms = decoded['elapsedMs'] ?? 0;
      final reply = decoded['reply']?.toString() ?? 'OK';
      return 'Nano 4 OK ($mode, ${ms}ms): "$reply"';
    }
    throw Exception(decoded['error']?.toString() ?? 'Nano 4 test failed.');
  } catch (e) {
    throw Exception('Nano 4 failed: $e');
  }
}

Future<LocalVisionSignals> extractLocalVisionSignalsImpl({
  required String? photoPath,
  required bool enableJapaneseOcr,
  required bool enableChineseOcr,
  required bool enableKoreanOcr,
}) async {
  // On Web, local analysis is handled by Chrome's on-device Gemini Nano 4
  // (or OsmHeuristicMapper when Nano is unavailable).
  return const LocalVisionSignals();
}
