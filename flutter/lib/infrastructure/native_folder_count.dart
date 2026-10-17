import 'dart:async';
import 'dart:io';

import '../application/folder_count_service.dart';

class NativeFolderCount implements FolderCountService {
  const NativeFolderCount({
    this.entryLimit = 10000,
    this.timeLimit = const Duration(seconds: 2),
  });
  final int entryLimit;
  final Duration timeLimit;
  @override
  Future<FolderCount> countFolder(
    String path, {
    required bool Function() cancelled,
  }) async {
    var count = 0, entries = 0;
    final elapsed = Stopwatch()..start();
    if (cancelled()) {
      return const FolderCount(0, false, '已取消统计');
    }
    try {
      await for (final entry in Directory(
        path,
      ).list(followLinks: false).timeout(timeLimit)) {
        if (cancelled()) {
          return FolderCount(count, false, '已取消统计');
        }
        if (++entries > entryLimit || elapsed.elapsed >= timeLimit) {
          return FolderCount(count, false, '达到统计上限，仅显示已发现文件');
        }
        if (entry is File) {
          final extension = entry.path.split('.').last.toLowerCase();
          if (const {'txt', 'epub', 'mobi', 'azw3'}.contains(extension)) {
            count++;
          }
        }
      }
      return FolderCount(
        count,
        true,
        '本层TXT/EPUB/MOBI/AZW3文件数；不含子文件夹，不代表内容已核验',
      );
    } on TimeoutException {
      return FolderCount(count, false, '统计超时，仅显示已发现文件');
    } on FileSystemException {
      return FolderCount(count, false, '文件夹无法读取，统计未完成');
    }
  }
}
