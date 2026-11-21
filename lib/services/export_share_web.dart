import 'dart:convert';
import 'dart:js_interop';

@JS('document.createElement')
external _JsElement _createElement(JSString tag);

@JS('document.body.appendChild')
external void _appendChild(_JsElement child);

@JS('document.body.removeChild')
external void _removeChild(_JsElement child);

extension type _JsElement(JSObject _) implements JSObject {
  external set href(JSString value);
  external set download(JSString value);
  external void click();
}

Future<void> shareOrDownloadExportImpl({
  required String content,
  required String fileName,
  required String subject,
}) async {
  final encoded = base64Encode(utf8.encode(content));
  final mime = fileName.endsWith('.geojson')
      ? 'application/geo+json'
      : 'application/xml';
  final anchor = _createElement('a'.toJS);
  anchor.href = 'data:$mime;charset=utf-8;base64,$encoded'.toJS;
  anchor.download = fileName.toJS;
  _appendChild(anchor);
  anchor.click();
  _removeChild(anchor);
}
