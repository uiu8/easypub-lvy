import '../application/storage_locations.dart';
import '../infrastructure/import_profile.dart';

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

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
    this.sourceEncoding,
    this.encodingSuspect = false,
  });
  final String path, sourceId, encoding;
  final int revision, lines, headings;
  final String? originPath;

  /// 手动选的编码（G-114）：这时 [path] 是转好的 UTF-8 工作稿。
  final String? sourceEncoding;

  /// 自动判断成 GBK，但看着像乱码。
  final bool encodingSuspect;

  /// 是不是用户的 TXT，手动选过编码的也算。
  bool get isPlainText => bookFormatForPath(originPath ?? path) == 'TXT';

  ImportedTxt flagged() => ImportedTxt(
    path: path,
    sourceId: sourceId,
    revision: revision,
    encoding: encoding,
    lines: lines,
    headings: headings,
    originPath: originPath,
    resourceReport: resourceReport,
    initialStructure: initialStructure,
    sourceEncoding: sourceEncoding,
    encodingSuspect: true,
  );
  final Map<String, dynamic>? resourceReport;
  final Map<String, dynamic>? initialStructure;
}

/// 文件解不开，要用户选编码（G-114）。
class UndecodableText extends FormatException {
  const UndecodableText() : super('文件解不开，请选择编码。');
}

typedef ImportTxt = Future<ImportedTxt> Function(
  String path,
  bool Function() cancelled,
);

/// Input formats that the current read-only importer can actually decode.
/// V131：AZW3 / MOBI（无 DRM）先转成 EPUB，再按 EPUB 导入。KFX 不支持。
const supportedBookImportExtensions = <String>{
  'txt',
  'epub',
  'azw3',
  'mobi',
  'azw',
};
const kindleBookImportExtensions = <String>{'azw3', 'mobi', 'azw'};

bool isSupportedBookImportPath(String path) =>
    supportedBookImportExtensions.contains(path.split('.').last.toLowerCase());

String bookFormatForPath(String path) {
  final extension = path.split('.').last.toLowerCase();
  return switch (extension) {
    'epub' => 'EPUB',
    'txt' => 'TXT',
    'azw3' || 'azw' => 'AZW3',
    'mobi' => 'MOBI',
    _ => extension.toUpperCase(),
  };
}

Future<ImportedTxt> readTxt(String path, bool Function() cancelled) =>
    ImportProfile.measureAsync(
      'native_import',
      () => _readTxtMeasured(path, cancelled),
    );

Future<ImportedTxt> _readTxtMeasured(
  String path,
  bool Function() cancelled,
) async {
  final file = File(path.trim());
  if (!file.isAbsolute || !path.toLowerCase().endsWith('.txt')) {
    throw const FormatException('请选择 TXT 文件的完整路径。');
  }
  final id = await startImport(path: file.path, ruleId: 'builtin-heading-v1');
  var cancellationSent = false, reachedEnd = false;
  Future<void> checkCancel() async {
    if (reachedEnd) return;
    if (cancelled() && !cancellationSent) {
      cancellationSent = true;
      await cancelImportJob(jobId: id);
    }
  }

  /// 处理一条状态（桥接第 2 批起为有类型的状态）：完成时返回结果，取消或失败时抛出，其余返回 null。
  Future<ImportedTxt?> handle(ImportJobStatus status) async {
    if (const {
      ImportPhase.completed,
      ImportPhase.cancelled,
      ImportPhase.failed,
    }.contains(status.phase)) {
      reachedEnd = true;
    }
    switch (status.phase) {
      case ImportPhase.completed:
        final source = status.source;
        if (source == null ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(source.sourceId)) {
          throw const FormatException('导入结果不完整，请重新导入。');
        }
        final classified = jsonDecode(
          await editStructureDraft(
            sourceId: source.sourceId,
            revision: source.revision,
            draftJson: '',
            commandJson: '{"op":"recognize"}',
          ),
        ) as Map;
        final structure = (classified['history'] as List).first as Map;
        return ImportedTxt(
          path: file.absolute.path,
          sourceId: source.sourceId,
          revision: source.revision,
          encoding: source.encoding,
          lines: source.lines,
          headings: source.chapters,
          initialStructure: structure.cast<String, dynamic>(),
        );
      case ImportPhase.cancelled:
        throw const FormatException('导入已取消。');
      case ImportPhase.failed:
        final failure = status.failure;
        final code = failure?.code ?? '';
        if (code == 'InvalidEncoding' || code == 'InvalidUtf8') {
          throw const UndecodableText();
        }
        throw FormatException(
          code == 'NotFound'
              ? '找不到文件，请核对路径。'
              : failure?.operation == 'session_budget'
              ? '书库驻留内容达到 512 MiB 或 10000 个源快照上限，请保存项目后开启另一工作区；已导入的书稿保留。'
              : code == 'TooLarge'
              ? 'TXT 单文件上限为 128 MiB。'
              : code == 'InvalidEncoding'
              ? '无法完整解码文件，请检查编码。'
              // R9：最常见的原因是文件正被其他程序独占（例如下载或编辑中）。
              : '文件读取失败：可能正被其他程序占用，或没有读取权限。请关闭占用它的程序后重试。',
        );
      default:
        return null;
    }
  }

  // 桥接第 1 批：状态由后端推送，不再反复查询。界面的取消标志仍要定时看一眼。
  final cancelWatch = Timer.periodic(
    const Duration(milliseconds: 20),
    (_) => checkCancel().catchError((_) {}),
  );
  try {
    await checkCancel();
    await for (final status in importJobStatusWatch(jobId: id)) {
      await checkCancel();
      final done = await handle(status);
      if (done != null) return done;
    }
  } catch (_) {
    // 已到终态时的错误（取消、失败、识别出错）照常抛出；推送本身出错时任务仍在后台运行，改用查询继续。
    if (reachedEnd) rethrow;
  } finally {
    cancelWatch.cancel();
  }
  var pollMilliseconds = 4;
  while (true) {
    await checkCancel();
    final done = await handle(await importJobStatus(jobId: id));
    if (done != null) return done;
    // 小文件通常几毫秒内完成，先短等；长任务退避到原来的 60ms 上限。
    await ImportProfile.measureAsync(
      'poll_wait',
      () => Future<void>.delayed(Duration(milliseconds: pollMilliseconds)),
    );
    pollMilliseconds = (pollMilliseconds * 2).clamp(4, 60);
  }
}

/// Import an EPUB by extracting its reading-order XHTML into a persistent
/// UTF-8 working copy, then send that copy through the normal Rust TXT reader.
/// The original EPUB remains untouched and is never treated as editable text.
Future<ImportedTxt> readBook(
  String path,
  bool Function() cancelled, {
  bool keepMarks = true,
  String? encoding,
}) async {
  final file = File(path.trim());
  if (!file.isAbsolute) {
    throw const FormatException('请选择书稿文件的完整路径。');
  }
  final extension = file.path.split('.').last.toLowerCase();
  if (extension == 'txt') {
    if (encoding != null) return _readEncoded(file, encoding, cancelled);
    final imported = await readTxt(file.path, cancelled);
    // 只有 GBK 会把别的编码解成“成功”，其他情况不用多读一遍。
    return imported.encoding == 'cp936' &&
            await textEncodingSuspect(path: file.path)
        ? imported.flagged()
        : imported;
  }
  if (extension != 'epub' && !kindleBookImportExtensions.contains(extension)) {
    throw const FormatException('目前支持 TXT、EPUB、AZW3、MOBI 文件。');
  }
  final root = Directory(await StorageLocations.retain('imports'));
  final EpubImportBundle bundle;
  try {
    final epub = kindleBookImportExtensions.contains(extension)
        ? await _kindleAsEpub(file, root, cancelled)
        : file;
    bundle = await EpubImportCache(
      root: root,
      keepMarks: keepMarks,
    ).read(epub, cancelled);
  } on ApiError catch (error) {
    throw FormatException(
      _bookErrorText(apiErrorInfo(error: error).nextAction),
    );
  }
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

/// EPUB、AZW3、MOBI 读不出来的真实原因。不要写成路径或权限问题。
String _bookErrorText(String action) => switch (action) {
  'choose_well_formed_epub_xhtml' => '这本书里有格式错误的页面，读不出来。可以修好这本 EPUB 后再导入。',
  'choose_utf8_epub_content' => '这本书的页面不是 UTF-8 编码，暂时读不了。',
  'choose_epub_with_readable_spine_text' => '这本书里没有读到正文。',
  'choose_valid_epub_zip' ||
  'choose_epub_with_container_and_content' ||
  'choose_valid_epub_package' ||
  'choose_epub_with_package_document' => '这个文件不是完整的 EPUB，可能已损坏。',
  final other when other.contains('drm') => '这本书带 DRM 保护，不能导入。',
  _ => '这本书读不出来，文件可能已损坏。',
};

/// 按选定的编码转成 UTF-8 工作稿再读（G-114），原文件不动。工作稿按内容和编码
/// 存，同一个文件再选同一种编码不用再转。
Future<ImportedTxt> _readEncoded(
  File source,
  String encoding,
  bool Function() cancelled,
) async {
  if (await source.length() > 128 * 1024 * 1024) {
    throw const FormatException('TXT 单文件上限为 128 MiB。');
  }
  final digest = (await sha256.bind(source.openRead()).first).toString();
  if (cancelled()) throw const FormatException('导入已取消。');
  final directory = Directory(
    p.join(await StorageLocations.retain('imports'), 'encoded'),
  );
  await directory.create(recursive: true);
  final name = '${digest.substring(0, 32)}-$encoding';
  final copy = File(p.join(directory.path, '$name.txt'));
  if (!await copy.exists()) {
    final pending = File(
      p.join(
        directory.path,
        '$name-${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await transcodeText(
      sourcePath: source.path,
      encoding: encoding,
      outputPath: pending.path,
    );
    await pending.rename(copy.path);
  }
  final imported = await readTxt(copy.path, cancelled);
  return ImportedTxt(
    path: imported.path,
    sourceId: imported.sourceId,
    revision: imported.revision,
    encoding: imported.encoding,
    lines: imported.lines,
    headings: imported.headings,
    originPath: source.path,
    initialStructure: imported.initialStructure,
    sourceEncoding: encoding,
  );
}

/// 已在书库的书补读原书标记（G-113）。[working] 是工作稿，文字要和原书读出来的
/// 一字不差。返回导入报告里的那一段。
Future<Map<String, dynamic>> rereadBookMarks(
  String origin,
  String working,
) async {
  final file = File(origin);
  if (!await file.exists()) {
    throw const FormatException('找不到原文件，无法补读。');
  }
  final root = Directory(await StorageLocations.retain('imports'));
  final extension = origin.split('.').last.toLowerCase();
  final epub = kindleBookImportExtensions.contains(extension)
      ? await _kindleAsEpub(file, root, () => false)
      : file;
  final bucket = Directory(p.join(root.path, 'marks'));
  await bucket.create(recursive: true);
  final target = await bucket.createTemp('m-');
  return (jsonDecode(
    await rereadEpubMarks(
      sourcePath: epub.path,
      textPath: working,
      resourceDir: target.path,
    ),
  ) as Map).cast<String, dynamic>();
}

/// AZW3 / MOBI 先转成 EPUB（V131，LIB-295）：按文件内容的哈希存在程序数据目录，同一文件再次导入时直接沿用。
/// 原文件不改；带 DRM 的文件由后端拒绝。
Future<File> _kindleAsEpub(
  File source,
  Directory root,
  bool Function() cancelled,
) async {
  if (await source.length() > 256 * 1024 * 1024) {
    throw const FormatException('文件上限为 256 MiB。');
  }
  final digest = (await sha256.bind(source.openRead()).first).toString();
  if (cancelled()) throw const FormatException('导入已取消。');
  final directory = Directory(p.join(root.path, 'kindle'));
  await directory.create(recursive: true);
  // -m：带行内样式和表格的读法（G-113），旧的转换结果不再用。
  final epub = File(
    p.join(directory.path, '${digest.substring(0, 32)}-m.epub'),
  );
  if (await epub.exists()) return epub;
  final pending = File(
    p.join(
      directory.path,
      '${digest.substring(0, 32)}-${DateTime.now().microsecondsSinceEpoch}.epub',
    ),
  );
  await importKindleEpub(sourcePath: source.path, outputPath: pending.path);
  if (cancelled()) {
    await pending.delete().catchError((_) => pending);
    throw const FormatException('导入已取消。');
  }
  try {
    await pending.rename(epub.path);
  } on FileSystemException {
    if (!await epub.exists()) rethrow;
    await pending.delete().catchError((_) => pending);
  }
  return epub;
}
