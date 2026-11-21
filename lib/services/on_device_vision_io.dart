import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'on_device_vision.dart';

const MethodChannel _nanoChannel =
    MethodChannel('com.edgemapper.app/gemini_nano');

Future<LocalNanoCheckResult> checkLocalNanoAvailabilityImpl() async {
  try {
    final result =
        await _nanoChannel.invokeMapMethod<String, dynamic>('checkAvailability');
    if (result != null) {
      return LocalNanoCheckResult(
        available: result['available'] == true,
        aicoreInstalled: result['aicoreInstalled'] == true,
        deviceModel: result['deviceModel']?.toString() ?? 'Android',
        sdkInt: (result['sdkInt'] as num?)?.toInt() ?? 0,
        reason: result['reason']?.toString() ?? '',
      );
    }
  } catch (e) {
    return LocalNanoCheckResult(
      available: false,
      aicoreInstalled: false,
      deviceModel: 'Android',
      sdkInt: 0,
      reason: 'ML Kit offline ready ($e).',
    );
  }
  return const LocalNanoCheckResult(
    available: false,
    aicoreInstalled: false,
    deviceModel: 'Android',
    sdkInt: 0,
    reason: 'ML Kit offline ready.',
  );
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
  if (photoPath == null) return null;
  onProgress?.call('Analyzing with Gemini Nano...');
  final nanoResponse = await _nanoChannel.invokeMapMethod<String, dynamic>(
    'generateOsmDraft',
    {
      'photoPath': photoPath,
      'latitude': latitude,
      'longitude': longitude,
      'headingDegrees': headingDegrees,
      'userHint': userHint,
    },
  );
  if (nanoResponse != null && nanoResponse['supported'] == true) {
    final rawJson = nanoResponse['json']?.toString();
    if (rawJson != null && rawJson.trim().isNotEmpty) {
      return rawJson;
    }
  }
  return null;
}

void cancelLocalNanoDraftImpl() {}

Future<String> testLocalNanoImpl() async {
  final check = await checkLocalNanoAvailabilityImpl();
  if (check.available) {
    return 'Gemini Nano ready (${check.deviceModel}): ${check.reason}';
  }
  return 'On-device ML Kit active (${check.deviceModel}): ${check.reason}';
}

Future<LocalVisionSignals> extractLocalVisionSignalsImpl({
  required String? photoPath,
  required bool enableJapaneseOcr,
  required bool enableChineseOcr,
  required bool enableKoreanOcr,
}) async {
  final labels = <String>[];
  final ocrLines = <String>{};
  double? maxOcrHeightRatio;

  if (photoPath != null && File(photoPath).existsSync()) {
    final inputImage = InputImage.fromFilePath(photoPath);

    double imageHeight = 0;
    try {
      final bytes = await File(photoPath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      imageHeight = frame.image.height.toDouble();
      frame.image.dispose();
      codec.dispose();
    } catch (_) {}

    final labeler = ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.55),
    );
    try {
      final detected = await labeler.processImage(inputImage);
      for (final label in detected) {
        labels.add(label.label);
      }
    } catch (e) {
      debugPrint('[EdgeMapper] ML Kit image labeling error: $e');
    } finally {
      await labeler.close();
    }

    final scripts = <TextRecognitionScript>[
      TextRecognitionScript.latin,
      if (enableJapaneseOcr) TextRecognitionScript.japanese,
      if (enableChineseOcr) TextRecognitionScript.chinese,
      if (enableKoreanOcr) TextRecognitionScript.korean,
    ];

    double maxLineHeightPx = 0;
    for (final script in scripts) {
      final recognizer = TextRecognizer(script: script);
      try {
        final recognized = await recognizer.processImage(inputImage);
        for (final block in recognized.blocks) {
          for (final line in block.lines) {
            final cleaned = line.text.trim();
            if (cleaned.length >= 2) {
              ocrLines.add(cleaned);
              maxLineHeightPx =
                  math.max(maxLineHeightPx, line.boundingBox.height);
            }
          }
        }
      } catch (e) {
        debugPrint('[EdgeMapper] ML Kit OCR ($script) error: $e');
      } finally {
        await recognizer.close();
      }
    }

    if (imageHeight > 0 && maxLineHeightPx > 0) {
      maxOcrHeightRatio = (maxLineHeightPx / imageHeight).clamp(0.0, 1.0);
    }
  }

  return LocalVisionSignals(
    imageLabels: labels,
    ocrLines: ocrLines.toList(),
    maxOcrHeightRatio: maxOcrHeightRatio,
  );
}
