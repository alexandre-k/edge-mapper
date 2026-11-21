import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<void> shareOrDownloadExportImpl({
  required String content,
  required String fileName,
  required String subject,
}) async {
  final dir = await getTemporaryDirectory();
  final safeBaseName = p.basename(fileName).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final finalName = safeBaseName.isEmpty || safeBaseName == '.' || safeBaseName == '..'
      ? 'edge_mapper_export.txt'
      : safeBaseName;
  final filePath = p.join(dir.path, finalName);
  final file = File(filePath);
  await file.writeAsString(content, flush: true);

  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(filePath)],
      subject: subject,
      text: 'Exported from Edge Mapper ($finalName)',
    ),
  );
}
