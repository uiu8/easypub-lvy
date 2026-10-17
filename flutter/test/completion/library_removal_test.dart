import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/output_task.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class NoPicker extends Fake implements BookFilePicker {}

Future<(PrototypeState, LegacyLibraryAdapter, String)> fixture() async {
  final root = (await Directory('../artifacts').createTemp('library-removal-'))
      .absolute
      .path;
  final state = PrototypeState(settingsDirectory: '$root/settings');
  final library = LegacyLibraryAdapter(backend: state);
  await library.load();
  await library.savePatch({'check_after_import': false});
  for (final name in ['甲', '乙']) {
    final file = File('$root/$name.txt');
    await file.writeAsString('第一章 开始\n正文$name\n');
    expect((await library.importFiles([file.path])).single.succeeded, true);
  }
  return (state, library, root);
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test('remove restores full draft and history, protects tasks and reimport, clears undo on project replacement', () async {
    final (state, library, root) = await fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final ids = library.books.value.map((b) => b.id).toList();
    final id = ids.first;
    final file = library.books.value.first.path;
    final original = await File(file).readAsBytes();
    library.selectBook(id);
    library.checkBooks(ids, true);
    final info = library.openBookInformation(id);
    await info.apply(
      await info.preview({'author': '保留作者', 'description': '保留简介'}),
    );
    info.dispose();
    final chapters = library.openChapters(id);
    var tree = await chapters.read(0);
    await chapters.confirm(
      await chapters.preview(tree, RenameChapter(tree.nodes.first.id, '手工章节')),
    );
    tree = await chapters.read(0);
    var stale = await chapters.preview(
      tree,
      RenameChapter(tree.nodes.first.id, '不应采用'),
    );
    final catalog = library.openCatalog(id);
    catalog.accept(await catalog.acquire('paste', '第一章 开始', declaredTotal: 1));
    tree = await chapters.read(0);
    stale = await chapters.preview(
      tree,
      RenameChapter(tree.nodes.first.id, '不应采用'),
    );
    final before = state.projectDocument();
    final beforeRow = (before['books'] as List).firstWhere(
      (b) => b['path'] == state.shelf.books.firstWhere((b) => b.id == id).path,
    );
    final task = OutputTask(
      bookId: id,
      title: 'book',
      sourceId: 'source',
      revision: 1,
      format: 'MOBI',
      outputPath: '$root/out.mobi',
    );
    state.outputs.tasks.add(task);
    expect(
      () => library.removeBooks({id}),
      throwsA(
        isA<LibraryRemovalBlocked>().having((e) => e.openTasks, 'tasks', true),
      ),
    );
    expect(library.books.value, hasLength(2));
    expect(library.removedBatchCount.value, 0);
    task.phase = 'cancelled';
    task.finishedAt = DateTime.now();
    state.outputs.batchBusy = true;
    expect(
      () => library.removeBooks({id}),
      throwsA(isA<LibraryRemovalBlocked>()),
    );
    state.outputs.batchBusy = false;
    library.removeBooks({id});
    final firstRemoval = library.removedBatches.single.id;
    expect(library.books.value, hasLength(1));
    expect(library.selection.value.current, ids.last);
    expect(library.selection.value.selected, {ids.last});
    expect(state.production.histories.containsKey(id), false);
    expect(state.manuscript.effectiveHistories.containsKey(id), false);
    expect(state.savedReferenceCatalog(id), isNull);
    final otherInfo = library.openBookInformation(ids.last);
    await otherInfo.apply(await otherInfo.preview({'author': '其他书的新编辑'}));
    otherInfo.dispose();
    library.undoBookRemoval();
    expect(state.production.settings(ids.last)['author'], '其他书的新编辑');
    expect(library.selection.value.current, id);
    expect(library.selection.value.selected, ids.toSet());
    final restored = (state.projectDocument()['books'] as List).firstWhere(
      (b) => b['path'] == beforeRow['path'],
    );
    expect(
      restored,
      beforeRow,
      reason:
          'whole book serialization including histories and reference catalog',
    );
    await expectLater(
      chapters.confirm(stale),
      throwsA(isA<ChapterStateChanged>()),
    );
    expect((await library.openChapters(id).read(0)).nodes.first.title, '手工章节');
    library.removeBooks({id});
    final oldVersion = library.removedBatches.first.id;
    expect((await library.importFiles([file])).single.succeeded, true);
    final newer = library.openBookInformation(id);
    await newer.apply(await newer.preview({'author': '新版作者'}));
    newer.dispose();
    expect(
      () => library.undoBookRemoval(batchId: oldVersion),
      throwsFormatException,
    );
    expect(state.production.settings(id)['author'], '新版作者');
    library.removeBooks({id});
    final newVersion = library.removedBatches.first.id;
    library.undoBookRemoval(batchId: oldVersion);
    expect(state.production.settings(id)['author'], '保留作者');
    expect(library.removedBatches.any((b) => b.id == newVersion), true);
    expect(library.removedBatches.any((b) => b.id == firstRemoval), false);
    library.removeBooks(library.books.value.map((b) => b.id).toSet());
    expect(library.books.value, isEmpty);
    expect(
      (await library.saveProject('$root/empty.easypub.json')).succeeded,
      true,
    );
    expect(
      jsonDecode(
        await File('$root/empty.easypub.json').readAsString(),
      )['books'],
      isEmpty,
    );
    library.undoBookRemoval();
    expect(library.books.value, hasLength(2));
    expect(
      (await library.saveProject('$root/restored.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/restored.easypub.json')).succeeded,
      true,
    );
    expect(library.removedBatchCount.value, 0);
    expect((await library.openChapters(id).read(0)).nodes.first.title, '手工章节');
    expect(state.production.settings(id)['author'], '保留作者');
    final conversion = library.openConversion();
    try {
      final preview = await conversion.preview(
        ConversionRequest(
          books: [id],
          directory: root,
          format: 'EPUB',
          runChecks: false,
        ),
      );
      expect(preview.previewed, true);
      final results = await conversion.commit(
        preview,
        acknowledgeWarnings: true,
      );
      expect(results.single.phase, 'complete', reason: results.single.detail);
      expect(await File(results.single.path).exists(), true);
    } finally {
      conversion.dispose();
    }
    expect(await File(file).readAsBytes(), original);
  });
  testWidgets(
    'row removal and batch removal expose undo even in empty library',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late (PrototypeState, LegacyLibraryAdapter, String) data;
      await t.runAsync(() async {
        data = await fixture();
      });
      expect(t.takeException(), isNull);
      final (state, library, _) = data;
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: LibraryPage(library: library, picker: NoPicker()),
          ),
        ),
      );
      final first = library.books.value.first;
      await t.tap(find.byTooltip('书籍操作：${first.title}'));
      await t.pumpAndSettle();
      await t.tap(find.text('从书库移除'));
      await t.pumpAndSettle();
      expect(library.books.value, hasLength(1));
      await t.tap(find.byKey(const ValueKey('library-undo-removal')));
      await t.pumpAndSettle();
      expect(library.books.value, hasLength(2));
      await t.tap(find.byTooltip('全选筛选结果'));
      await t.pump();
      await t.tap(find.text('移除所选'));
      await t.pumpAndSettle();
      expect(library.books.value, isEmpty);
      expect(find.text('把第一本书放进书库'), findsOneWidget);
      await t.tap(find.byTooltip('关闭提示'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-undo-removal')), findsNothing);
      expect(library.books.value, isEmpty);
      await t.tap(find.text('撤销移除'));
      await t.pumpAndSettle();
      expect(library.books.value, hasLength(2));
      expect(library.selection.value.selected, hasLength(2));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
