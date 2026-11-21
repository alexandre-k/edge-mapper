import 'gps_file_picker_io.dart'
    if (dart.library.js_interop) 'gps_file_picker_web.dart';

class PickedGpsFile {
  final String fileName;
  final String content;

  const PickedGpsFile({
    required this.fileName,
    required this.content,
  });
}

/// Opens the native system file picker (Android Storage Access Framework or Web
/// `<input type="file">`) to read a Ham radio GPS log (`.nmea`, `.log`, `.txt`,
/// `.aprs`, `.gpx`, `.kml`, `.csv`). Returns `null` if the user cancels.
Future<PickedGpsFile?> pickGpsLogFile() => pickGpsLogFileImpl();
