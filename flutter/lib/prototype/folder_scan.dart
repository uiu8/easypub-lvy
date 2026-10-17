import 'dart:io';
import 'dart:async';
import 'dart:collection';

import 'package:path/path.dart' as p;

import 'txt_import.dart';

String folderImportPathKey(String path) =>
    p.normalize(p.absolute(path)).toLowerCase();

class FolderScanEntry {
  const FolderScanEntry(this.path, this.bytes, this.alreadyImported);
  final String path;
  final int bytes;
  final bool alreadyImported;
  String get name => path.replaceAll('\\', '/').split('/').last;
  String get format => bookFormatForPath(path);
}

class FolderScanResult {
  const FolderScanResult(
    this.entries,
    this.skipped,
    this.message,
    this.complete, {
    this.resume,
    this.close,
    this.failures = const [],
  });
  final List<FolderScanEntry> entries;
  final int skipped;
  final String message;
  final bool complete;
  final Future<FolderScanResult> Function(bool Function())? resume;
  final void Function()? close;
  final List<String> failures;
}

/// Enumerates only. No book is decoded and no library state is changed here.
Future<FolderScanResult> scanBookFolder(
  String path, {
  required bool recursive,
  required bool Function() cancelled,
  Set<String> importedPaths = const {},
  int maxEntries = 10000,
  int maxBooks = 10000,
  bool retainCursor = false,
}) async {
  final cursor = BookFolderScan(
    path,
    recursive: recursive,
    importedPaths: importedPaths,
    maxEntries: maxEntries,
    maxBooks: maxBooks,
  );
  final result = await cursor.next(cancelled);
  if (retainCursor) return result;
  cursor.close();
  return FolderScanResult(
    result.entries,
    result.skipped,
    result.message,
    result.complete,
    failures: result.failures,
  );
}

/// Keeps the directory stream position; retry enumerates only failed paths.
class BookFolderScan {
  BookFolderScan(
    String path, {
    required this.recursive,
    Set<String> importedPaths = const {},
    this.maxEntries = 10000,
    this.maxBooks = 10000,
    Stream<FileSystemEntity> Function(Directory)? listDirectory,
  }) : known = importedPaths.map(folderImportPathKey).toSet(),
       listDirectory = listDirectory ?? ((d) => d.list(followLinks: false)) {
    pending.add(Directory(path.trim()).absolute);
  }
  final bool recursive;
  final int maxEntries, maxBooks;
  final Set<String> known;
  final Stream<FileSystemEntity> Function(Directory) listDirectory;
  final pending = Queue<FileSystemEntity>();
  final failed = <String, FileSystemEntity>{};
  final seen = <String>{};
  final entries = <FolderScanEntry>[];
  StreamIterator<FileSystemEntity>? active;
  Directory? activeDirectory;
  int skipped = 0;
  bool closed = false, busy = false;
  void close() {
    closed = true;
    final old = active;
    active = null;
    unawaited(old?.cancel());
  }

  Future<FolderScanResult> next(bool Function() cancelled) async {
    if (closed || busy) throw StateError('扫描已关闭或仍在进行');
    busy = true;
    // Failed paths are retried once per explicit continuation, not in a loop.
    pending.addAll(failed.values);
    failed.clear();
    var visited = 0, added = 0;
    var reason = '';
    try {
      while (!closed) {
        if (cancelled()) {
          reason = '已取消扫描。';
          break;
        }
        if (visited >= maxEntries || added >= maxBooks) {
          reason = '达到本次扫描上限，可继续扫描。';
          break;
        }
        FileSystemEntity? entity;
        if (active != null) {
          final iterator = active!;
          try {
            if (await iterator.moveNext()) {
              entity = iterator.current;
            } else {
              await iterator.cancel();
              active = null;
              activeDirectory = null;
              continue;
            }
          } on FileSystemException {
            if (activeDirectory != null) {
              failed[activeDirectory!.path] = activeDirectory!;
            }
            await iterator.cancel();
            active = null;
            activeDirectory = null;
            continue;
          }
        } else if (pending.isNotEmpty) {
          entity = pending.removeFirst();
          if (entity is Directory) {
            try {
              if (await FileSystemEntity.type(
                    entity.path,
                    followLinks: false,
                  ) !=
                  FileSystemEntityType.directory) {
                failed[entity.path] = entity;
                continue;
              }
              if (closed) break;
              activeDirectory = entity;
              active = StreamIterator(listDirectory(entity));
            } on FileSystemException {
              failed[entity.path] = entity;
            }
            continue;
          }
        } else {
          break;
        }
        if (closed) continue;
        visited++;
        final key = folderImportPathKey(entity.path);
        if (seen.contains(key)) continue;
        if (entity is Directory) {
          seen.add(key);
          if (recursive) pending.add(entity);
          continue;
        }
        if (entity is! File) {
          seen.add(key);
          continue;
        }
        if (!isSupportedBookImportPath(entity.path)) {
          seen.add(key);
          skipped++;
          continue;
        }
        try {
          final stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file) {
            failed[entity.path] = entity;
            continue;
          }
          seen.add(key);
          entries.add(
            FolderScanEntry(
              entity.absolute.path,
              stat.size,
              known.contains(key),
            ),
          );
          added++;
        } on FileSystemException {
          failed[entity.path] = entity;
        }
      }
      final complete =
          !closed &&
          active == null &&
          pending.isEmpty &&
          failed.isEmpty &&
          reason.isEmpty;
      final sorted = List<FolderScanEntry>.of(entries)
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      final errors = List<String>.unmodifiable(failed.keys);
      final message = complete
          ? '找到 ${entries.length} 本书稿，跳过 $skipped 个不支持的文件。'
          : '$reason${errors.isEmpty ? '' : '${errors.length} 个路径读取失败，可重试：${errors.take(3).join('；')}。'} 已保留 ${entries.length} 本可选书稿；尚未导入。';
      return FolderScanResult(
        List.unmodifiable(sorted),
        skipped,
        message,
        complete,
        resume: complete || closed ? null : next,
        close: complete ? null : close,
        failures: errors,
      );
    } finally {
      if (closed) close();
      busy = false;
    }
  }
}
