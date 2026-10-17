// 检查结果缓存文件（设置目录 check-reports/）的命名、统计与清理（V19，CHK-061）。
// 只处理名为 64 位十六进制 + .json 的缓存文件；不读不写书稿。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as paths;

import '../application/check_cache_service.dart';

/// 某一稿的检查报告缓存文件名（指纹前加 v3 前缀，沿用 V12 起的命名）。
String checkReportFileName(String guard) =>
    '${sha256.convert(utf8.encode('v3:$guard'))}.json';

final _reportName = RegExp(r'^[0-9a-f]{64}\.json$');
const _recordName = 'cleanup-record.json';

class _Entry {
  _Entry(this.file, this.bytes, this.modified, this.bookId, this.checkedAt);
  final File file;
  final int bytes;
  final DateTime modified;
  final String bookId;
  final DateTime? checkedAt;
  DateTime get when => checkedAt ?? modified;
  String get name => file.uri.pathSegments.last;
}

Future<List<_Entry>> _entries(Directory directory) async {
  final result = <_Entry>[];
  if (!await directory.exists()) return result;
  await for (final item in directory.list(followLinks: false)) {
    if (item is! File) continue;
    final name = item.uri.pathSegments.last;
    if (!_reportName.hasMatch(name)) continue;
    final stat = await item.stat();
    var bookId = '';
    DateTime? checkedAt;
    try {
      if (stat.size < 262144) {
        final value = jsonDecode(await item.readAsString()) as Map;
        bookId = value['book_id'] as String? ?? '';
        checkedAt = DateTime.tryParse(value['checked_at'] as String? ?? '');
      }
    } catch (_) {
      // 读不出来的缓存无法归属到书，按“无法归属”处理。
    }
    result.add(_Entry(item, stat.size, stat.modified, bookId, checkedAt));
  }
  return result;
}

/// 按保留规则统计：书库中的书保留当前稿与上一稿；其他项目中的书按书的标识
/// 保留最近两份；无法归属的旧报告只在它是某本书当前稿的结果时保留。
/// [currentGuards] 为书库中每本书 → 当前稿的检查指纹。
Future<CheckCachePreview> previewCheckReportCleanup(
  Directory directory,
  Map<String, String> currentGuards,
) async {
  final entries = await _entries(directory);
  final current = {
    for (final e in currentGuards.entries) checkReportFileName(e.value): e.key,
  };
  final keep = <String>{};
  for (final e in entries) {
    if (current.containsKey(e.name)) keep.add(e.name);
  }
  final byBook = <String, List<_Entry>>{};
  for (final e in entries.where((e) => e.bookId.isNotEmpty)) {
    (byBook[e.bookId] ??= []).add(e);
  }
  for (final MapEntry(key: book, value: list) in byBook.entries) {
    list.sort((a, b) => b.when.compareTo(a.when));
    final others = list.where((e) => !current.containsKey(e.name));
    // 书库中的书：当前稿之外再留一份（上一稿）；不在书库中的书：留最近两份。
    keep.addAll(
      others.take(currentGuards.containsKey(book) ? 1 : 2).map((e) => e.name),
    );
  }
  var unattributed = 0, unattributedBytes = 0, older = 0, olderBytes = 0;
  final files = <({String path, int bytes, DateTime modified})>[];
  for (final e in entries) {
    if (keep.contains(e.name)) continue;
    if (e.bookId.isEmpty) {
      unattributed++;
      unattributedBytes += e.bytes;
    } else {
      older++;
      olderBytes += e.bytes;
    }
    files.add((path: e.file.path, bytes: e.bytes, modified: e.modified));
  }
  return CheckCachePreview(
    total: entries.length,
    totalBytes: entries.fold(0, (sum, e) => sum + e.bytes),
    unattributed: unattributed,
    unattributedBytes: unattributedBytes,
    older: older,
    olderBytes: olderBytes,
    kept: entries.length - files.length,
    files: List.unmodifiable(files),
    lastCleanup: await _lastCleanup(directory),
  );
}

Future<({DateTime at, int deleted, int bytes})?> _lastCleanup(
  Directory directory,
) async {
  try {
    final file = File('${directory.path}/$_recordName');
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString()) as Map;
    final at = DateTime.tryParse(value['at'] as String? ?? '');
    if (at == null) return null;
    return (
      at: at,
      deleted: value['deleted'] as int? ?? 0,
      bytes: value['bytes'] as int? ?? 0,
    );
  } catch (_) {
    return null;
  }
}

/// 删除预览中列出的文件。删除前逐个核对：仍在原目录、大小与修改时间未变、
/// 也没有又成为书库中某本书当前稿的结果；否则跳过。
Future<CheckCacheCleanupResult> cleanCheckReports(
  Directory directory,
  CheckCachePreview preview,
  Map<String, String> currentGuards,
) async {
  final current = {
    for (final guard in currentGuards.values) checkReportFileName(guard),
  };
  var deleted = 0, bytes = 0, skipped = 0;
  for (final item in preview.files) {
    final file = File(item.path);
    final name = file.uri.pathSegments.last;
    if (!paths.equals(paths.dirname(item.path), directory.path) ||
        !_reportName.hasMatch(name) ||
        current.contains(name)) {
      skipped++;
      continue;
    }
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != item.bytes ||
          stat.modified != item.modified) {
        skipped++;
        continue;
      }
      await file.delete();
      deleted++;
      bytes += item.bytes;
    } on FileSystemException {
      skipped++;
    }
  }
  try {
    await File('${directory.path}/$_recordName').writeAsString(
      jsonEncode({
        'at': DateTime.now().toIso8601String(),
        'deleted': deleted,
        'bytes': bytes,
        'skipped': skipped,
      }),
      flush: true,
    );
  } catch (_) {
    // 清理记录写不进去不影响已删除的结果；结果仍会返回给页面。
  }
  return CheckCacheCleanupResult(deleted, bytes, skipped);
}
