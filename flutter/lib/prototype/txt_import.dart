import 'dart:io';
import 'dart:convert';

import 'epub_import_cache.dart';

import '../src/rust/api.dart';

/// Read-only import summary. Rust owns bounded immutable source snapshots.
class ImportedTxt {
  const ImportedTxt({
    required this.path,
    required this.sourceId,
    required this.revision,
    required this.encoding,
    required this.lines,
    required this.headings,
    this.originPath,
    this.resourceReport,
    this.initialStructure,
  });
  final String path, sourceId, encoding;
  final int revision, lines, headings;
  final String? originPath;
  final Map<String, dynamic>? resourceReport;
  final Map<String, dynamic>? initialStructure;
}

typedef ImportTxt = Future<ImportedTxt> Function(
  String path,
  bool Function() cancelled,
);

/// Input formats that the current read-only importer can actually decode.
/// Output formats (AZW3/MOBI) are intentionally absent: importing an
/// existing Kindle container is a separate capability from producing one.
const supportedBookImportExtensions = <String>{'txt', 'epub'};

bool isSupportedBookImportPath(String path) =>
    supportedBookImportExtensions.contains(path.split('.').last.toLowerCase());

String bookFormatForPath(String path) {
  final extension = path.split('.').last.toLowerCase();
  return switch (extension) {
    'epub' => 'EPUB',
    'txt' => 'TXT',
    _ => extension.toUpperCase(),
  };
}

Future<ImportedTxt> readTxt(String path, bool Function() cancelled) async {
  final file = File(path.trim());
  if (!file.isAbsolute || !path.toLowerCase().endsWith('.txt')) {
    throw const FormatException('请选择 TXT 文件的完整路径。');
  }
  final id = await startImport(path: file.path, ruleId: 'builtin-heading-v1');
  var cancellationSent = false;
  while (true) {
    if (cancelled() && !cancellationSent) {
      await cancelJobText(jobId: id);
      cancellationSent = true;
    }
    final raw = await jobStatusText(jobId: id);
    final fields = <String, String>{};
    for (final segment in raw.split(';')) {
      final index = segment.indexOf('=');
      if (index > 0) {
        fields[segment.substring(0, index)] = segment.substring(index + 1);
      }
    }
    if (fields['phase'] == 'Completed') {
      final revision = int.tryParse(fields['revision'] ?? '');
      final lines = int.tryParse(fields['lines'] ?? '');
      final headings = int.tryParse(fields['chapters'] ?? '');
      final source = fields['source_id'] ?? '';
      if (revision == null ||
          lines == null ||
          headings == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(source)) {
        throw const FormatException('导入结果不完整，请重新导入。');
      }
      final classified = jsonDecode(
        await editStructureDraft(
          sourceId: source,
          revision: revision,
          draftJson: '',
          commandJson: '{"op":"recognize"}',
        ),
      ) as Map;
      final structure = (classified['history'] as List).first as Map;
      return ImportedTxt(
        path: file.absolute.path,
        sourceId: source,
        revision: revision,
        encoding: fields['encoding'] ?? '',
        lines: lines,
        headings: headings,
        initialStructure: structure.cast<String, dynamic>(),
      );
    }
    if (fields['phase'] == 'Cancelled') throw const FormatException('导入已取消。');
    if (fields['phase'] == 'Failed') {
      final error = fields['error'] ?? '';
      throw FormatException(
        error.contains('NotFound')
            ? '找不到文件，请核对路径。'
            : error.contains('session_budget')
            ? '书库驻留内容达到 512 MiB 或 10000 个源快照上限，请保存项目后开启另一工作区；已导入的书稿保留。'
            : error.contains('TooLarge')
            ? 'TXT 单文件上限为 128 MiB。'
            : error.contains('InvalidEncoding')
            ? '无法完整解码文件，请检查编码。'
            : '文件读取失败，请检查文件权限和内容。',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }
}

/// Import an EPUB by extracting its reading-order XHTML into a persistent
/// UTF-8 working copy, then send that copy through the normal Rust TXT reader.
/// The original EPUB remains untouched and is never treated as editable text.
Future<ImportedTxt> readBook(String path, bool Function() cancelled) async {
  final file = File(path.trim());
  if (!file.isAbsolute) {
    throw const FormatException('请选择书稿文件的完整路径。');
  }
  final extension = file.path.split('.').last.toLowerCase();
  if (extension == 'txt') return readTxt(file.path, cancelled);
  if (extension != 'epub') {
    throw const FormatException('目前支持 TXT 和 EPUB 文件。');
  }
  final root = Directory(
    Platform.environment['LOCALAPPDATA'] == null
        ? '${Directory.systemTemp.path}${Platform.pathSeparator}easypub-epub-imports'
        : '${Platform.environment['LOCALAPPDATA']}${Platform.pathSeparator}EasyPub-RustFlutter${Platform.pathSeparator}imports',
  );
  final bundle = await EpubImportCache(root: root).read(file, cancelled);
  final imported = await readTxt(bundle.textPath, cancelled);
  return ImportedTxt(
    path: imported.path,
    sourceId: imported.sourceId,
    revision: imported.revision,
    encoding: imported.encoding,
    lines: imported.lines,
    headings: imported.headings,
    originPath: file.path,
    resourceReport: bundle.resources,
  );
}
