import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/prototype/folder_scan.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/folders/folder_controller.dart';

import 'folder_scale_test.dart' show RecordingLibrary;

void main() {
  test('closing during async directory setup cancels a late stream', () async {
    final root = await Directory.systemTemp.createTemp('folder77-close-');
    var opened = 0, cancelled = 0;
    final cursor = BookFolderScan(
      root.path,
      recursive: true,
      listDirectory: (_) {
        opened++;
        return StreamController<FileSystemEntity>(onCancel: () => cancelled++)
            .stream;
      },
    );
    final pending = cursor.next(() => false);
    cursor.close();
    final result = await pending;
    await Future<void>.delayed(Duration.zero);
    expect(result.resume, isNull);
    expect(cancelled, opened);
    await expectLater(cursor.next(() => false), throwsStateError);
  });
  test('closing a suspended scan cancels its active subscription', () async {
    final root = await Directory.systemTemp.createTemp('folder77-suspended-');
    var cancelled = false;
    late StreamController<FileSystemEntity> stream;
    stream = StreamController<FileSystemEntity>(
      onListen: () => stream.add(File('${root.path}/skip.bin')),
      onCancel: () {
        cancelled = true;
      },
    );
    final cursor = BookFolderScan(
      root.path,
      recursive: true,
      maxEntries: 1,
      listDirectory: (_) => stream.stream,
    );
    final page = await cursor.next(() => false);
    expect(page.complete, false);
    page.close!();
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, true);
  });
  test(
    'cursor passes 10000 items without restarting and cancellation resumes',
    () async {
      final root = await Directory.systemTemp.createTemp('folder77-');
      final file = File('${root.path}/book.txt')..writeAsStringSync('正文');
      var openings = 0, emitted = 0;
      final cursor = BookFolderScan(
        root.path,
        recursive: true,
        listDirectory: (d) async* {
          openings++;
          for (var i = 0; i < 10001; i++) {
            emitted++;
            yield File('${root.path}/skip-$i.bin');
          }
          emitted++;
          yield file;
        },
      );
      addTearDown(cursor.close);
      var page = await cursor.next(() => false);
      expect(page.complete, false);
      expect(emitted, 10000);
      expect(page.entries, isEmpty);
      page = await page.resume!(() => true);
      expect(emitted, 10000);
      expect(page.complete, false);
      page = await page.resume!(() => false);
      expect(page.complete, true);
      expect(openings, 1);
      expect(emitted, 10002);
      expect(page.skipped, 10001);
      expect(page.entries.single.path, file.absolute.path);
      expect(page.resume, isNull);
    },
  );

  test(
    'failed child keeps other results and retry deduplicates partial directory',
    () async {
      final root = await Directory.systemTemp.createTemp('folder77-retry-');
      final bad = Directory('${root.path}/bad')..createSync();
      final good = Directory('${root.path}/good')..createSync();
      final first = File('${bad.path}/first.txt')..writeAsStringSync('甲');
      final last = File('${bad.path}/last.epub')..writeAsStringSync('乙');
      final other = File('${good.path}/other.txt')..writeAsStringSync('丙');
      var blocked = true;
      final opened = <String, int>{};
      final cursor = BookFolderScan(
        root.path,
        recursive: true,
        listDirectory: (d) async* {
          opened[d.path] = (opened[d.path] ?? 0) + 1;
          if (d.path == root.path) {
            yield bad;
            yield good;
          } else if (d.path == bad.path) {
            yield first;
            if (blocked) {
              throw FileSystemException('simulated unreadable child', d.path);
            }
            yield last;
          } else {
            yield other;
          }
        },
      );
      addTearDown(cursor.close);
      var page = await cursor.next(() => false);
      expect(page.complete, false);
      expect(page.failures, [bad.path]);
      expect(
        page.entries.map((e) => e.path),
        unorderedEquals([first.path, other.path]),
      );
      blocked = false;
      page = await page.resume!(() => false);
      expect(page.complete, true);
      expect(page.failures, isEmpty);
      expect(
        page.entries.map((e) => e.path),
        unorderedEquals([first.path, last.path, other.path]),
      );
      expect(opened[root.path], 1);
      expect(opened[good.path], 1);
      expect(opened[bad.path], 2);
    },
  );

  test('controller continuation keeps deselection and never reselects imported books', () async {
    var closed = false;
    final second = FolderListing(
      const [
        FolderBook('a.txt', 1, true),
        FolderBook('b.txt', 1, false),
        FolderBook('c.txt', 1, false),
      ],
      0,
      true,
      '完成',
    );
    final first = FolderListing(
      const [FolderBook('a.txt', 1, false), FolderBook('b.txt', 1, false)],
      0,
      false,
      '上限',
      resume: (_) async => second,
      close: () => closed = true,
    );
    final model = FolderController(RecordingLibrary(first));
    await model.scan('root');
    model.toggle('b.txt', false);
    await model.resumeScan();
    expect(model.selected, {'c.txt'});
    expect(model.listing!.books.length, 3);
    model.dispose();
    expect(closed, false); // Completed cursor owns no open stream.
    final abandoned = FolderController(RecordingLibrary(first));
    await abandoned.scan('root');
    abandoned.dispose();
    expect(closed, true);
  });
}
