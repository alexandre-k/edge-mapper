import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'gps_file_picker.dart';

Future<PickedGpsFile?> pickGpsLogFileImpl() async {
  final completer = Completer<PickedGpsFile?>();
  final input = web.document.createElement('input') as web.HTMLInputElement;
  input.type = 'file';
  input.accept = '.nmea,.log,.txt,.aprs,.gpx,.kml,.csv,.xml,text/plain';
  input.style.display = 'none';

  void cleanup() {
    input.remove();
  }

  late final JSFunction onChange;
  late final JSFunction onCancel;

  onChange = ((web.Event _) {
    final files = input.files;
    if (files == null || files.length == 0) {
      cleanup();
      if (!completer.isCompleted) completer.complete(null);
      return;
    }
    final file = files.item(0);
    if (file == null) {
      cleanup();
      if (!completer.isCompleted) completer.complete(null);
      return;
    }
    const maxBytes = 12 * 1024 * 1024;
    if (file.size > maxBytes) {
      cleanup();
      if (!completer.isCompleted) {
        completer.completeError(
          Exception('GPS log file exceeds the 12 MB import limit.'),
        );
      }
      return;
    }
    final reader = web.FileReader();
    reader.onload = ((web.Event _) {
      final text = reader.result?.dartify()?.toString() ?? '';
      cleanup();
      if (!completer.isCompleted) {
        completer.complete(
          PickedGpsFile(fileName: file.name, content: text),
        );
      }
    }).toJS;
    reader.onerror = ((web.Event _) {
      cleanup();
      if (!completer.isCompleted) completer.complete(null);
    }).toJS;
    reader.readAsText(file);
  }).toJS;

  onCancel = ((web.Event _) {
    cleanup();
    if (!completer.isCompleted) completer.complete(null);
  }).toJS;

  input.addEventListener('change', onChange);
  input.addEventListener('cancel', onCancel);
  web.document.body?.append(input);
  input.click();

  return completer.future;
}
