import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:easypub_desktop/application/settings_service.dart';

import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/folders/folder_controller.dart';
import 'package:easypub_desktop/prototype/folder_scan.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordingLibrary implements LibraryService {
  RecordingLibrary(this.listing);
  final FolderListing listing;
  final batches = <List<String>>[];
  void Function()? onBatch;
  bool cancelled = false;
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
  }) async {
    if (paths.length > 128) throw const FormatException('batch exceeds 128');
    batches.add(List.of(paths));
    onBatch?.call();
    return paths.map((p) => ImportOutcome(p, true, 'ok')).toList();
  }

  @override
  void cancelImport() {
    cancelled = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class LoadingLibrary extends RecordingLibrary implements SettingsService {
  LoadingLibrary() : super(const FolderListing([], 0, true, 'ok'));
  final loaded = Completer<bool>();
  @override
  Future<bool> load() => loaded.future;
  @override
  final ValueNotifier<SettingsSnapshot> snapshot = ValueNotifier(
    const SettingsSnapshot(
      configuration: {'import_recursive': true},
      status: '',
      busy: false,
      loaded: true,
      theme: 'light',
      reducedMotion: false,
    ),
  );
  int scans = 0;
  @override
  Future<FolderListing> scanFolder(
    String path, {
    required bool recursive,
    required bool Function() cancelled,
  }) async {
    scans++;
    return listing;
  }
}

void main() {
  test(
    'settings loading participates in scan progress cancellation and failure',
    () async {
      final library = LoadingLibrary();
      final model = FolderController(library);
      addTearDown(model.dispose);
      addTearDown(library.snapshot.dispose);
      final pending = model.scan('D:/synthetic');
      expect(model.scanning, true);
      model.cancel();
      library.loaded.complete(true);
      await pending;
      expect(library.scans, 0);
      expect(model.scanning, false);
      expect(model.message, '已取消扫描。');
      final failing = LoadingLibrary();
      final failed = FolderController(failing);
      addTearDown(failed.dispose);
      addTearDown(failing.snapshot.dispose);
      final failure = failed.scan('D:/synthetic');
      failing.loaded.completeError(StateError('settings unavailable'));
      await failure;
      expect(failed.busy, false);
      expect(failed.message, contains('扫描失败'));
    },
  );
  test('128, 129 and 256 files remain selectable; bounded/cancelled scan keeps partial results', () async {
    final root = await Directory.systemTemp.createTemp(
      'folder-scale-regression-',
    );
    for (var i = 0; i < 256; i++) {
      await File('${root.path}/book-$i.txt').writeAsString('第一章 测试\n正文\n');
      if ([127, 128, 255].contains(i)) {
        final scan = await scanBookFolder(
          root.path,
          recursive: true,
          cancelled: () => false,
        );
        expect(scan.complete, true, reason: '${i + 1} books: ${scan.message}');
        expect(scan.entries, hasLength(i + 1));
      }
    }
    final limited = await scanBookFolder(
      root.path,
      recursive: true,
      cancelled: () => false,
      maxEntries: 5,
    );
    expect(limited.complete, false);
    expect(limited.entries, hasLength(5));
    var visits = 0;
    final cancelled = await scanBookFolder(
      root.path,
      recursive: true,
      cancelled: () => ++visits > 5,
    );
    expect(cancelled.complete, false);
    expect(cancelled.entries, isNotEmpty);
    final model = FolderController(
      RecordingLibrary(
        FolderListing(
          limited.entries
              .map((e) => FolderBook(e.path, e.bytes, false))
              .toList(),
          0,
          false,
          limited.message,
        ),
      ),
    );
    addTearDown(model.dispose);
    await model.scan(root.path);
    expect(model.canImport, true);
  });

  test('selected folder books submit bounded batches and cancellation stops next batch', () async {
    final listing = FolderListing(
      List.generate(256, (i) => FolderBook('D:/synthetic/$i.txt', 10, false)),
      0,
      true,
      'ok',
    );
    final library = RecordingLibrary(listing);
    final model = FolderController(library);
    addTearDown(model.dispose);
    await model.scan('D:/synthetic');
    await model.importSelected();
    expect(library.batches.map((b) => b.length), [128, 128]);
    expect(model.outcomes, hasLength(256));
    expect(model.selected, isEmpty);
    final stopping = RecordingLibrary(listing);
    final interrupted = FolderController(stopping);
    addTearDown(interrupted.dispose);
    stopping.onBatch = interrupted.cancel;
    await interrupted.scan('D:/synthetic');
    await interrupted.importSelected();
    expect(stopping.batches, hasLength(1));
    expect(stopping.cancelled, true);
    expect(interrupted.outcomes, hasLength(128));
    expect(interrupted.selected, hasLength(128));
    stopping.onBatch = null;
    await interrupted.importSelected();
    expect(stopping.batches, hasLength(2));
    expect(interrupted.selected, isEmpty);
  });
}
