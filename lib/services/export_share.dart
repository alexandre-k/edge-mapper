import 'export_share_io.dart'
    if (dart.library.js_interop) 'export_share_web.dart' as impl;

Future<void> shareOrDownloadExport({
  required String content,
  required String fileName,
  required String subject,
}) =>
    impl.shareOrDownloadExportImpl(
      content: content,
      fileName: fileName,
      subject: subject,
    );
