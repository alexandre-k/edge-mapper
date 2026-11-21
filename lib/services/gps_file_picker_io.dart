import 'package:flutter/services.dart';

import 'gps_file_picker.dart';

const MethodChannel _filePickerChannel =
    MethodChannel('com.edgemapper.app/file_picker');

Future<PickedGpsFile?> pickGpsLogFileImpl() async {
  try {
    final raw = await _filePickerChannel.invokeMethod<dynamic>('pickTextFile');
    if (raw is Map) {
      final name = raw['fileName']?.toString() ?? 'radio_track.log';
      final content = raw['content']?.toString() ?? '';
      if (content.isNotEmpty) {
        return PickedGpsFile(fileName: name, content: content);
      }
    }
    return null;
  } on PlatformException {
    rethrow;
  } catch (_) {
    return null;
  }
}
