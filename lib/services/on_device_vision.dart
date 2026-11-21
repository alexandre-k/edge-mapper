import 'on_device_vision_io.dart'
    if (dart.library.js_interop) 'on_device_vision_web.dart' as impl;

class LocalNanoCheckResult {
  final bool available;
  final bool aicoreInstalled;
  final String deviceModel;
  final int sdkInt;
  final String reason;

  const LocalNanoCheckResult({
    required this.available,
    required this.aicoreInstalled,
    required this.deviceModel,
    required this.sdkInt,
    required this.reason,
  });
}

class LocalVisionSignals {
  final List<String> imageLabels;
  final List<String> ocrLines;
  final double? maxOcrHeightRatio;

  const LocalVisionSignals({
    this.imageLabels = const [],
    this.ocrLines = const [],
    this.maxOcrHeightRatio,
  });
}

Future<LocalNanoCheckResult> checkLocalNanoAvailability() =>
    impl.checkLocalNanoAvailabilityImpl();

Future<String?> runLocalNanoDraft({
  required String prompt,
  String? photoPath,
  required double latitude,
  required double longitude,
  double? headingDegrees,
  String? userHint,
  void Function(String step)? onProgress,
}) =>
    impl.runLocalNanoDraftImpl(
      prompt: prompt,
      photoPath: photoPath,
      latitude: latitude,
      longitude: longitude,
      headingDegrees: headingDegrees,
      userHint: userHint,
      onProgress: onProgress,
    );

void cancelLocalNanoDraft() => impl.cancelLocalNanoDraftImpl();

Future<String> testLocalNano() => impl.testLocalNanoImpl();

Future<LocalVisionSignals> extractLocalVisionSignals({
  required String? photoPath,
  required bool enableJapaneseOcr,
  required bool enableChineseOcr,
  required bool enableKoreanOcr,
}) =>
    impl.extractLocalVisionSignalsImpl(
      photoPath: photoPath,
      enableJapaneseOcr: enableJapaneseOcr,
      enableChineseOcr: enableChineseOcr,
      enableKoreanOcr: enableKoreanOcr,
    );
