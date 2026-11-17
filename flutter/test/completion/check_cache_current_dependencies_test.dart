import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/application/check_cache_service.dart';
import 'package:easypub_desktop/infrastructure/check_report_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('清理预览后的新报告复用旧位置缓存，stat 后切换也保留', () async {
    final root = await Directory.systemTemp.createTemp('easypub-cache-race-');
    addTearDown(() => root.delete(recursive: true));
    final used = File('${root.path}/${checkSpotsFileName('shared-text')}')
      ..writeAsBytesSync([1, 2, 3]);
    final unused = File('${root.path}/${checkSpotsFileName('unused')}')
      ..writeAsBytesSync([4, 5]);
    Future<CheckCachePreview> preview(List<File> files) async =>
        CheckCachePreview(
          total: files.length,
          totalBytes: 0,
          unattributed: files.length,
          unattributedBytes: 0,
          older: 0,
          olderBytes: 0,
          kept: 0,
          files: [
            for (final file in files)
              (
                path: file.path,
                bytes: file.lengthSync(),
                modified: file.lastModifiedSync(),
              ),
          ],
        );
    final proposed = await preview([used, unused]);
    File('${root.path}/${checkReportFileName('new-metadata')}')
        .writeAsStringSync(
          jsonEncode({
            'guards': {'cleanup': 'shared-text'},
          }),
        );
    var reads = 0;
    final result = await cleanCheckReports(
      root,
      proposed,
      {},
      latestGuards: () {
        reads++;
        // 第一次删除前检查尚无当前报告；异步 stat 后，报告已切换。
        return reads == 1 ? {} : {'book': 'new-metadata'};
      },
    );
    expect(reads, greaterThanOrEqualTo(2));
    expect(result.deleted, 1);
    expect(result.skipped, 1);
    expect(used.existsSync(), isTrue);
    expect(unused.existsSync(), isFalse);

    final again = await preview([used]);
    final result2 = await cleanCheckReports(root, again, {
      'book': 'missing-report',
    });
    expect(result2.deleted, 0, reason: '当前报告不可读时不能猜测位置缓存已废弃');
    expect(used.existsSync(), isTrue);
  });
}
