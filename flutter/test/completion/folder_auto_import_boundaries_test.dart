import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/folder_auto_import.dart';
import 'package:easypub_desktop/application/library_service.dart';

class _Library implements LibraryService {
  late FolderListing listing;
  final batches = <List<String>>[];
  int? failBatch;
  bool shortBatch = false;
  @override
  final ValueNotifier<List<BookSummary>> books = ValueNotifier([]);
  @override
  Future<FolderListing> scanFolder(
    String path, {
    required bool recursive,
    required bool Function() cancelled,
  }) async => listing;
  @override
  Future<List<ImportOutcome>> importFiles(
    List<String> paths, {
    bool skipExisting = false,
    bool interactive = true,
  }) async {
    expect(skipExisting, true);
    expect(interactive, false);
    expect(paths.length, lessThanOrEqualTo(128));
    batches.add(List.of(paths));
    if (batches.length == failBatch)
      throw StateError('simulated import failure');
    return [
      for (final path in (shortBatch ? paths.take(1) : paths))
        ImportOutcome(path, true, ''),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late _Library library;
  late FolderAutoImporter importer;
  setUp(() async {
    root = await Directory('../artifacts').createTemp('auto-import-boundary-');
    library = _Library();
    importer = FolderAutoImporter(
      library: library,
      folders: () => [root.path],
      ignored: () => {},
      recursive: () => false,
      busy: () => false,
      watch: false,
    );
  });
  tearDown(() {
    importer.dispose();
    library.books.dispose();
  });
  List<FolderBook> rows(int from, int count) => [
    for (var i = from; i < from + count; i++)
      FolderBook('${root.path}/book-$i.txt', 12, false),
  ];
  test('扫描续页去重，260 本按 128/128/4 导入并关闭游标', () async {
    var resumed = 0, closed = 0;
    final close = () => closed++;
    library.listing = FolderListing(
      rows(0, 130),
      0,
      false,
      '',
      close: close,
      resume: (cancelled) async {
        expect(cancelled(), false);
        resumed++;
        return FolderListing(rows(129, 131), 0, true, '', close: close);
      },
    );
    final result = await importer.sync();
    expect(resumed, 1);
    expect(closed, 1);
    expect(library.batches.map((b) => b.length), [128, 128, 4]);
    expect(result.imported.length, 260);
    expect(result.failed, isEmpty);
    expect(result.deferred, false);
    expect(importer.state.value.running, false);
  });
  test('第二批异常保留第一批成果，短返回停止后续批次', () async {
    library.listing = FolderListing(rows(0, 260), 0, true, '');
    library.failBatch = 2;
    final failed = await importer.sync();
    expect(failed.imported.length, 128);
    expect(failed.failed.length, 128);
    expect(failed.deferred, true);
    expect(library.batches.length, 2);
    expect(importer.state.value.running, false);
    library.batches.clear();
    library.failBatch = null;
    library.shortBatch = true;
    final stopped = await importer.sync();
    expect(stopped.imported.length, 1);
    expect(stopped.deferred, true);
    expect(library.batches.length, 1);
    expect(importer.state.value.running, false);
  });
  test('续扫失败关闭游标且不丢失已扫描候选，报告未完成', () async {
    var closed = 0;
    library.listing = FolderListing(
      rows(0, 2),
      0,
      false,
      '',
      close: () => closed++,
      resume: (_) async => throw StateError('scan failed'),
    );
    final result = await importer.sync();
    expect(closed, 1);
    expect(result.imported.length, 2);
    expect(importer.state.value.running, false);
    expect(importer.state.value.message, contains('扫描失败'));
  });
}
