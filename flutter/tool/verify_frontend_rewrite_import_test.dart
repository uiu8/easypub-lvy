import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/frontend_rewrite/features/chapters/chapter_target_dialog.dart';
import 'package:easypub_desktop/frontend_rewrite/features/chapters/chapters_page.dart';
import 'package:easypub_desktop/desk/repair/repair_states.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class _Picker implements BookFilePicker {
  _Picker(this.path);
  final String path;
  int calls = 0;
  @override
  Future<String?> chooseFolder() async => File(path).parent.path;
  @override
  Future<String?> chooseProject() async => null;
  @override
  Future<String?> chooseProjectDestination() async => null;
  @override
  Future<List<String>> chooseBooks() async {
    calls++;
    return [path];
  }
}

void main() {
  testWidgets('independent new entry imports using real DLL without source mutation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    late Directory root;
    late File source;
    await tester.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File(
            Platform.environment['EASYPUB_TEST_DLL'] ??
                '../target/release/easypub_bridge.dll',
          ).absolute.path,
        ),
      );
      root = await Directory('../artifacts/frontend-rewrite/import-probe')
          .create(recursive: true);
      root = await root.createTemp('current-flow-');
      source = File('${root.absolute.path}/新前端导入.txt');
      final oldExtra = File('${root.absolute.path}/可选书稿.txt');
      if (await oldExtra.exists()) await oldExtra.delete();
      await source.writeAsString('第一章 渡口\n江边来信。\n第二章 夜雨\n窗外细雨。\n');
      for (final entry in {
        'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(entry.key)..addFont(
              File(entry.value)
                  .readAsBytes()
                  .then((b) => b.buffer.asByteData()),
            ))
            .load();
      }
    });
    final library = LegacyLibraryAdapter(
      settingsDirectory: '${root.absolute.path}/settings',
    );
    addTearDown(library.dispose);
    await tester.runAsync(() async {
      await library.load();
      await library.savePatch({
        'check_after_import': false,
        'import_recursive': false,
      });
    });
    Future<void> settle() async {
      for (var i = 0; i < 250; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (i > 3 &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();
    }

    final picker = _Picker(source.path);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: RewriteApp(library: library, picker: picker),
      ),
    );
    await settle();
    expect(find.text('把第一本书放进书库'), findsOneWidget);
    Future<void> screenshot(String name, {GlobalKey? captureKey}) async {
      await tester.runAsync(() async {
        final boundary =
            (captureKey ?? boundaryKey).currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${root.path}/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    await screenshot('empty');
    final before = await tester.runAsync(source.readAsBytes);
    await tester.runAsync(() async {
      await tester.tap(find.text('选择文件'));
      for (var i = 0; i < 100 && library.books.value.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await settle();
    expect(picker.calls, 1);
    expect(library.books.value.single.chapters, 2);
    expect(find.text('新前端导入'), findsWidgets);
    expect(await tester.runAsync(source.readAsBytes), before);
    expect(tester.takeException(), isNull);
    await screenshot('library');
    final extra = File('${root.path}/可选书稿.txt');
    await tester.runAsync(() => extra.writeAsString('第一章 山路\n林间小路。\n山风吹来。\n'));
    await tester.tap(find.text('文件夹').first);
    await settle();
    await tester.runAsync(() async {
      await tester.tap(find.text('浏览…'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settle();
    expect(find.text('导入所选 1 本'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('收藏此文件夹'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settle();
    expect(library.favoriteFolders.value, hasLength(1));
    await tester.tap(find.byTooltip('管理收藏'));
    await settle();
    await tester.tap(find.text(library.favoriteName(root.absolute.path)).last);
    await settle();
    await tester.tap(find.text('重命名'));
    await settle();
    await tester.enterText(
      find.byKey(const ValueKey('favorite-name-input')),
      '待制作书稿',
    );
    await tester.tap(find.text('保存名称'));
    await settle();
    expect(library.favoriteName(root.absolute.path), '待制作书稿');
    await screenshot('favorites');
    await tester.runAsync(() async {
      await tester.tap(find.text('打开文件夹'));
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.text('打开文件夹').evaluate().isEmpty) {
          break;
        }
      }
    });
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'folder scan must complete after closing favorites',
    );
    await settle();
    ScaffoldMessenger.of(tester.element(find.text('文件夹与收藏'))).clearSnackBars();
    await settle();
    expect(
      library.books.value.length,
      1,
      reason: 'scanning alone never imports',
    );
    expect(find.text('文件夹与收藏'), findsOneWidget);
    await screenshot('folders');
    await tester.runAsync(() async {
      await tester.tap(find.text('导入所选 1 本'));
      for (var i = 0; i < 100 && library.books.value.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await settle();
    expect(library.books.value.length, 2);
    expect(find.textContaining('导入 1 本，'), findsOneWidget);
    final selectedId = library.books.value.first.id;
    library.selectBook(selectedId);
    library.checkBook(selectedId, true);
    await tester.tap(find.text('元数据映射'));
    await settle();
    expect(find.text('元数据映射'), findsOneWidget);
    await tester.tap(find.text('添加规则'));
    await settle();
    await tester.runAsync(() async {
      await tester.tap(find.text('浏览目录…'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settle();
    await tester.tap(find.byKey(const ValueKey('0-author-keep')));
    await settle();
    await tester.tap(find.text('设为指定值').last);
    await settle();
    await tester.enterText(
      find.byKey(const ValueKey('mapping-value-author')),
      '映射作者',
    );
    await tester.tap(find.text('书库').first);
    await settle();
    expect(find.text('规则尚未保存'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await settle();
    expect(find.text('元数据映射'), findsOneWidget);
    await tester.tap(find.text('保存规则配置'));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
      if (find.text('仅保存规则').evaluate().isNotEmpty) break;
    }
    await tester.tap(find.text('仅保存规则'));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
      if (library.openMapping().rules.isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    await settle();
    expect(library.openMapping().rules, hasLength(1));
    await screenshot('metadata-mapping');
    final originalAuthors = library.books.value.map((b) => b.author).toList();
    await tester.runAsync(() async {
      await tester.tap(find.text('预览逐书差异'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle();
    expect(find.text('确认应用到 1 本书'), findsOneWidget);
    expect(
      library.books.value.map((b) => b.author).toList(),
      originalAuthors,
      reason: 'mapping preview does not mutate drafts',
    );
    await screenshot('metadata-mapping-diff');
    await tester.runAsync(() async {
      await tester.tap(find.text('确认应用到 1 本书'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle();
    expect(library.books.value.first.author, '映射作者');
    expect(
      library.books.value.last.author,
      originalAuthors.last,
      reason: 'unchecked books remain untouched',
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('返回文件夹'));
    await settle();
    await tester.tap(find.text('返回书库'));
    await settle();
    expect(library.selection.value.current, selectedId);
    expect(library.selection.value.selected, {selectedId});
    Future<void> chapterAction(Future<void> Function() action) async {
      await tester.runAsync(() async {
        await action();
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 25));
          if (i > 2 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty) {
            break;
          }
        }
      });
      await settle();
    }

    await chapterAction(() => tester.tap(find.text('章节').first));
    expect(find.text('章节树'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await screenshot('chapters');
    final chapterSession = library.openChapters(selectedId);
    final initialTree = (await tester.runAsync(() => chapterSession.read(0)))!;
    final node = initialTree.nodes.first;
    final initialBody = (await tester.runAsync(
      () => chapterSession.body(initialTree, node.id, 0),
    ))!;
    expect(initialTree.nodes.length, lessThanOrEqualTo(30));
    expect(initialBody.lines, isNotEmpty);
    expect(initialBody.lines.length, lessThanOrEqualTo(30));
    await tester.tap(find.text('改名'));
    await settle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '预览并确认'))
          .onPressed,
      isNull,
      reason: 'unchanged title must not create an edit',
    );
    await tester.enterText(
      find.byKey(const ValueKey('chapter-rename-input')),
      '   ',
    );
    await settle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '预览并确认'))
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey('chapter-rename-input')),
      '第一章 新章节标题',
    );
    await settle();
    await screenshot('chapter-rename');
    await chapterAction(() => tester.tap(find.text('预览并确认')));
    expect(find.text('改名预览'), findsOneWidget);
    expect(
      (await tester.runAsync(() => chapterSession.read(0)))!.nodes.first.title,
      node.title,
      reason: 'rename preview must not change the draft',
    );
    await chapterAction(() => tester.tap(find.text('返回调整')));
    expect(find.byKey(const ValueKey('chapter-rename-input')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('chapter-rename-input')))
          .controller!
          .text,
      '第一章 新章节标题',
    );
    await chapterAction(() => tester.tap(find.text('预览并确认')));
    await chapterAction(() => tester.tap(find.text('确认写入草稿')));
    expect(find.text('第一章 新章节标题'), findsWidgets);
    await chapterAction(() => tester.tap(find.text('撤销')));
    expect(find.text('第一章 新章节标题'), findsNothing);
    await chapterAction(() => tester.tap(find.text('重做')));
    expect(find.text('第一章 新章节标题'), findsWidgets);
    final editedTree = (await tester.runAsync(() => chapterSession.read(0)))!;
    expect(
      editedTree.nodes.first.id,
      node.id,
      reason: 'rename must preserve stable structure ID',
    );
    final editedBody = (await tester.runAsync(
      () => chapterSession.body(editedTree, node.id, 0),
    ))!;
    expect(editedBody.lines, initialBody.lines);
    await chapterAction(
      () => tester.tap(find.byKey(const ValueKey('chapter-toc'))),
    );
    final tocTree = (await tester.runAsync(() => chapterSession.read(0)))!;
    expect(tocTree.nodes.first.inToc, isFalse);
    final extraBytes = await tester.runAsync(extra.readAsBytes);
    await chapterAction(() => tester.tap(find.text('切分')));
    await tester.tap(find.text('山风吹来。').last);
    await tester.enterText(find.byKey(const ValueKey('split-title')), '第二章 山风');
    await settle();
    await screenshot('chapter-split');
    await chapterAction(() => tester.tap(find.text('预览并确认')));
    expect(
      (await tester.runAsync(() => chapterSession.read(0)))!.total,
      tocTree.total,
      reason: 'preview must not mutate draft',
    );
    await chapterAction(() => tester.tap(find.text('确认分章')));
    var splitTree = (await tester.runAsync(() => chapterSession.read(0)))!;
    expect(splitTree.total, tocTree.total + 1);
    final splitNode = splitTree.nodes.firstWhere((n) => n.title == '第二章 山风');
    await chapterAction(
      () => tester.tap(find.widgetWithText(TextButton, '移动').last),
    );
    await tester.tap(find.byKey(const ValueKey('target-end')));
    await settle();
    await screenshot('chapter-move');
    await chapterAction(() => tester.tap(find.text('预览并确认')));
    expect(
      (await tester.runAsync(() => chapterSession.read(0)))!.nodes.first.id,
      node.id,
    );
    expect(find.text('移动预览'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('确认写入草稿')));
    expect(
      (await tester.runAsync(() => chapterSession.read(0)))!.nodes.last.id,
      node.id,
    );
    await chapterAction(() => tester.tap(find.text('撤销')));
    await chapterAction(
      () => tester.tap(find.widgetWithText(TextButton, '合并').last),
    );
    await tester.tap(find.byKey(ValueKey('target-${splitNode.id}')));
    await settle();
    await tester.tap(find.byKey(const ValueKey('merge-title-policy')));
    await settle();
    await tester.tap(find.text('自定义标题').last);
    await settle();
    await tester.enterText(find.byKey(const ValueKey('merge-title')), '合并后的山路');
    await settle();
    await screenshot('chapter-merge');
    await chapterAction(() => tester.tap(find.text('预览并确认')));
    expect(
      (await tester.runAsync(() => chapterSession.read(0)))!.total,
      splitTree.total,
    );
    expect(find.text('合并预览'), findsOneWidget);
    expect(find.text('合并后的山路'), findsWidgets);
    await chapterAction(() => tester.tap(find.text('修改前')));
    expect(find.text('共 2 节点'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('修改后')));
    expect(find.text('共 1 节点'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('确认写入草稿')));
    expect(
      (await tester.runAsync(() => chapterSession.read(0)))!.nodes.single.title,
      '合并后的山路',
    );
    expect(
      (await tester.runAsync(() => chapterSession.read(0)))!.total,
      tocTree.total,
    );
    await chapterAction(() => tester.tap(find.text('撤销')));
    splitTree = (await tester.runAsync(() => chapterSession.read(0)))!;
    expect(splitTree.nodes.map((n) => n.title), [
      '第一章 新章节标题',
      '第二章 山风',
    ], reason: 'one undo restores both merge and title');
    await tester.runAsync(() async {
      final firstBody = await chapterSession.body(splitTree, node.id, 0);
      final secondBody = await chapterSession.body(splitTree, splitNode.id, 0);
      expect(firstBody.lines, contains('林间小路。'));
      expect(firstBody.lines, isNot(contains('山风吹来。')));
      expect(secondBody.lines, contains('山风吹来。'));
      final splitProject =
          '${root.absolute.path}/split-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
      expect((await library.saveProject(splitProject)).succeeded, isTrue);
      final reopened = LegacyLibraryAdapter();
      try {
        expect((await reopened.openProject(splitProject)).succeeded, isTrue);
        final reopenedSession = reopened.openChapters(selectedId);
        final tree = await reopenedSession.read(0);
        expect(tree.nodes.map((n) => n.id), splitTree.nodes.map((n) => n.id));
        expect(
          (await reopenedSession.body(tree, splitNode.id, 0)).lines,
          secondBody.lines,
        );
      } finally {
        reopened.dispose();
      }
      final move = await chapterSession.preview(
        splitTree,
        MoveChapter(splitNode.id, node.id),
      );
      final movedPreview = await chapterSession.previewTree(move, 0);
      expect(movedPreview.nodes.first.id, splitNode.id);
      expect((await chapterSession.read(0)).nodes.first.id, node.id);
      await chapterSession.confirm(move);
      await expectLater(chapterSession.confirm(move), throwsFormatException);
      final moved = await chapterSession.read(0);
      await chapterSession.history(moved, undo: true);
      final restoredSplit = await chapterSession.read(0);
      final merge = await chapterSession.preview(
        restoredSplit,
        MergeChapter(splitNode.id, node.id),
      );
      final mergedPreview = await chapterSession.previewTree(merge, 0);
      expect(mergedPreview.total, tocTree.total);
      final mergedBody = await chapterSession.previewBody(merge, node.id, 0);
      expect(mergedBody.lines.where((s) => s.isNotEmpty), ['林间小路。', '山风吹来。']);
      expect((await chapterSession.read(0)).total, splitTree.total);
      await chapterSession.confirm(merge);
      final merged = await chapterSession.read(0);
      await chapterSession.history(merged, undo: true);
      final beforeStale = await chapterSession.read(0);
      final stale = await chapterSession.preview(
        beforeStale,
        MoveChapter(splitNode.id, node.id),
      );
      await chapterSession.history(beforeStale, undo: true);
      await expectLater(chapterSession.confirm(stale), throwsFormatException);
      expect((await chapterSession.read(0)).total, tocTree.total);
    });
    expect(await tester.runAsync(extra.readAsBytes), extraBytes);
    expect(await tester.runAsync(source.readAsBytes), before);
    await tester.tap(find.text('书库').first);
    await settle();
    await tester.tap(find.text('项目'));
    await settle();
    expect(find.text('项目菜单'), findsOneWidget);
    await screenshot('project-menu');
    await tester.runAsync(() async {
      final projectPath =
          '${root.absolute.path}/roundtrip-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
      final saved = await library.saveProject(projectPath);
      expect(saved.succeeded, isTrue, reason: saved.message);
      final projectBytes = await File(projectPath).readAsBytes();
      final duplicate = await library.saveProject(projectPath);
      expect(
        duplicate.succeeded,
        isFalse,
        reason: 'existing project must not be overwritten',
      );
      expect(await File(projectPath).readAsBytes(), projectBytes);
      final restored = LegacyLibraryAdapter(
        settingsDirectory: '${root.absolute.path}/settings',
      );
      try {
        await restored.load();
        final opened = await restored.openProject(projectPath);
        expect(opened.succeeded, isTrue, reason: opened.message);
        expect(restored.books.value.length, 2);
        expect(restored.books.value.first.author, '映射作者');
        expect(restored.openMapping().rules, hasLength(1));
        final reopenedTree = await restored
            .openChapters(restored.books.value.first.id)
            .read(0);
        expect(reopenedTree.nodes.first.title, '第一章 新章节标题');
        expect(reopenedTree.nodes.first.inToc, isFalse);
        final mapping = restored.openMapping();
        final rules = mapping.rules;
        final pending = await mapping.preview(rules, [
          restored.books.value.first.id,
        ]);
        await restored.openMapping().saveRules([]);
        await expectLater(
          mapping.apply(pending),
          throwsFormatException,
          reason: 'changing project rules invalidates pending confirmation',
        );
        expect(restored.books.value.first.author, '映射作者');
        final fresh = restored.openMapping();
        await expectLater(
          fresh.preview(
            [rules.single, rules.single],
            [restored.books.value.first.id],
          ),
          throwsA(anything),
          reason: 'duplicate canonical folders must be rejected by Rust',
        );
        final rejected = await restored.openProject(
          '${root.absolute.path}/missing.easypub.json',
        );
        expect(rejected.succeeded, isFalse);
        expect(
          restored.books.value.length,
          2,
          reason: 'failed open preserves library',
        );
      } finally {
        restored.dispose();
      }
      expect(await source.readAsBytes(), before);
      final settings =
          '${root.absolute.path}/favorites-${DateTime.now().microsecondsSinceEpoch}';
      final favorites = LegacyLibraryAdapter(settingsDirectory: settings);
      try {
        expect(await favorites.loadFavorites(), isTrue);
        expect(await favorites.setFavorite(root.absolute.path, true), isTrue);
        expect(favorites.favoriteFolders.value, hasLength(1));
        expect(
          await favorites.renameFavorite(root.absolute.path, '待制作书稿'),
          isTrue,
        );
      } finally {
        favorites.dispose();
      }
      final reopenedFavorites = LegacyLibraryAdapter(
        settingsDirectory: settings,
      );
      try {
        expect(await reopenedFavorites.loadFavorites(), isTrue);
        expect(reopenedFavorites.favoriteFolders.value, hasLength(1));
        final savedPath = reopenedFavorites.favoriteFolders.value.single;
        expect(await Directory(savedPath).exists(), isTrue);
        expect(reopenedFavorites.favoriteName(savedPath), '待制作书稿');
        expect(await reopenedFavorites.renameFavorite(savedPath, ' '), isFalse);
        expect(reopenedFavorites.favoriteName(savedPath), '待制作书稿');
        final relocated = await Directory(
          '${root.absolute.path}/relocated-favorite',
        ).create();
        expect(
          await reopenedFavorites.relocateFavorite(savedPath, relocated.path),
          isTrue,
        );
        expect(reopenedFavorites.favoriteName(relocated.path), '待制作书稿');
        expect(
          await Directory(savedPath).exists(),
          isTrue,
          reason: 'relocation must not move original files',
        );
      } finally {
        reopenedFavorites.dispose();
      }
      final removedFavorites = LegacyLibraryAdapter(
        settingsDirectory: settings,
      );
      try {
        expect(await removedFavorites.loadFavorites(), isTrue);
        final relocatedPath = removedFavorites.favoriteFolders.value.single;
        expect(removedFavorites.favoriteName(relocatedPath), '待制作书稿');
        expect(
          await removedFavorites.setFavorite(relocatedPath, false),
          isTrue,
        );
        expect(await removedFavorites.loadFavorites(), isTrue);
        expect(removedFavorites.favoriteFolders.value, isEmpty);
        expect(removedFavorites.favoriteNames.value, isEmpty);
      } finally {
        removedFavorites.dispose();
      }
    });
    await tester.pumpWidget(const SizedBox());
    final pagedLibrary = LegacyLibraryAdapter();
    addTearDown(pagedLibrary.dispose);
    final pagedSource = File(
      '${root.absolute.parent.path}/paging-probe/chapters.txt',
    );
    await tester.runAsync(() async {
      await pagedSource.parent.create(recursive: true);
      await pagedSource.writeAsString(
        List.generate(65, (i) => '第${i + 1}章 标题${i + 1}\n正文${i + 1}。\n').join(),
      );
      final imported = await pagedLibrary.importFiles([pagedSource.path]);
      expect(imported.single.succeeded, isTrue);
    });
    final pagedSession = pagedLibrary.openChapters(
      pagedLibrary.books.value.single.id,
    );
    final pageOne = (await tester.runAsync(() => pagedSession.read(0)))!;
    expect(pageOne.total, 65);
    final combined = (await tester.runAsync(
      () => pagedSession.read(
        0,
        includeBody: true,
        preferredNodeId: pageOne.nodes[2].id,
      ),
    ))!;
    expect(combined.bodyNodeId, pageOne.nodes[2].id);
    expect(combined.body!.lines, contains('正文3。'));
    final combinedNext = (await tester.runAsync(
      () => pagedSession.read(
        30,
        includeBody: true,
        preferredNodeId: pageOne.nodes[2].id,
      ),
    ))!;
    expect(combinedNext.offset, 0);
    expect(combinedNext.bodyNodeId, pageOne.nodes[2].id);
    expect(combinedNext.body!.lines, contains('正文3。'));
    final renameCandidate = (await tester.runAsync(
      () => pagedSession.preview(
        pageOne,
        RenameChapter(pageOne.nodes[2].id, '第3章 修订标题'),
      ),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChapterCandidateDialog(
            session: pagedSession,
            preview: renameCandidate,
            originalPage: pageOne,
            title: '指定节点预览',
            initialNodeId: pageOne.nodes[2].id,
          ),
        ),
      ),
    );
    await chapterAction(() async {});
    expect(
      find.text('正文3。'),
      findsOneWidget,
      reason:
          'preview must initially display the renamed node, not the first node',
    );
    expect(find.text('正文1。'), findsNothing);
    expect(
      (await tester.runAsync(() => pagedSession.read(0)))!.nodes[2].title,
      '第3章 标题3',
    );
    expect(pagedSession.canUndo, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ChapterTargetDialog(
                  session: pagedSession,
                  page: pageOne,
                  node: pageOne.nodes.first,
                  merge: false,
                ),
              ),
              child: const Text('打开跨页移动'),
            ),
          ),
        ),
      ),
    );
    await chapterAction(() => tester.tap(find.text('打开跨页移动')));
    await chapterAction(() => tester.tap(find.byTooltip('下一页目标')));
    expect(find.text('第31章 标题31'), findsOneWidget);
    await tester.tap(find.text('第31章 标题31'));
    await settle();
    await chapterAction(() => tester.tap(find.text('预览并确认')));
    expect(find.text('第31章 标题31'), findsWidgets);
    expect(
      find.text('移动预览'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' | '),
    );
    await chapterAction(() => tester.tap(find.byTooltip('下一页预览结构')));
    expect(find.text('第65章 标题65'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('第65章 标题65')));
    expect(find.text('正文65。'), findsOneWidget);
    await tester.tap(find.text('返回调整'));
    await settle();
    await tester.tap(find.text('取消'));
    await settle();
    expect(
      (await tester.runAsync(() => pagedSession.read(0)))!.nodes.first.id,
      pageOne.nodes.first.id,
    );
    expect(
      pagedSession.canUndo,
      isFalse,
      reason: 'cancelled candidate must not append history',
    );
    await chapterAction(() => tester.tap(find.text('打开跨页移动')));
    await chapterAction(() => tester.tap(find.byTooltip('下一页目标')));
    await tester.tap(find.text('第31章 标题31'));
    await settle();
    await chapterAction(() => tester.tap(find.text('预览并确认')));
    await chapterAction(() => tester.tap(find.text('确认写入草稿')));
    final movedPage = (await tester.runAsync(() => pagedSession.read(0)))!;
    expect(movedPage.nodes.first.title, '第2章 标题2');
    expect(movedPage.nodes.last.id, pageOne.nodes.first.id);
    expect(
      await tester.runAsync(pagedSource.readAsString),
      List.generate(65, (i) => '第${i + 1}章 标题${i + 1}\n正文${i + 1}。\n').join(),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    final volumeSource = File(
      '${root.absolute.parent.path}/paging-probe/volumes.txt',
    );
    const volumeText =
        '第一卷 起\n引言甲\n第一章 甲\n甲正文\n第二卷 终\n引言乙\n第二章 乙\n乙正文\n第三卷 空\n引言丙\n';
    await tester.runAsync(() async {
      await volumeSource.writeAsString(volumeText);
      expect(
        (await pagedLibrary.importFiles([volumeSource.path])).single.succeeded,
        isTrue,
      );
    });
    final volumeBook = pagedLibrary.books.value.firstWhere(
      (b) => b.path == volumeSource.path,
    );
    final volumeSession = pagedLibrary.openChapters(volumeBook.id);
    final volumeTree = (await tester.runAsync(() => volumeSession.read(0)))!;
    final volumes = (await tester.runAsync(
      () => volumeSession.volumes(volumeTree, 0),
    ))!;
    expect(volumes.total, 3);
    final chapter = volumeTree.nodes.firstWhere((n) => n.role == 'chapter');
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ChapterTargetDialog(
                  session: volumeSession,
                  page: volumeTree,
                  node: chapter,
                  merge: false,
                ),
              ),
              child: const Text('打开卷移动'),
            ),
          ),
        ),
      ),
    );
    await chapterAction(() => tester.tap(find.text('打开卷移动')));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await settle();
    await chapterAction(() => tester.tap(find.text('第三卷 空').last));
    await tester.tap(find.text('卷末'));
    await settle();
    await chapterAction(() => tester.tap(find.text('预览并确认')));
    expect(
      (await tester.runAsync(() => volumeSession.read(0)))!.nodes[1].id,
      chapter.id,
    );
    await chapterAction(() => tester.tap(find.text('确认写入草稿')));
    final movedVolumes = (await tester.runAsync(() => volumeSession.read(0)))!;
    expect(movedVolumes.nodes.last.id, chapter.id);
    expect(movedVolumes.nodes.last.depth, 1);
    final lastChildren = (await tester.runAsync(
      () => volumeSession.volumes(
        movedVolumes,
        0,
        volumeId: volumes.nodes.last.id,
      ),
    ))!;
    expect(lastChildren.nodes.single.id, chapter.id);
    expect(await tester.runAsync(volumeSource.readAsString), volumeText);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    final issuesSource = File(
      '${root.absolute.parent.path}/paging-probe/issues.txt',
    );
    const issuesText = '第一章 起\n正文甲\n第三章 终\n正文乙\n';
    await tester.runAsync(() async {
      await issuesSource.writeAsString(issuesText);
      expect(
        (await pagedLibrary.importFiles([issuesSource.path])).single.succeeded,
        isTrue,
      );
    });
    final issuesBook = pagedLibrary.books.value.firstWhere(
      (b) => b.path == issuesSource.path,
    );
    final issueSession = pagedLibrary.openChapters(issuesBook.id);
    final issueTree = (await tester.runAsync(() => issueSession.read(0)))!;
    final oldIssues = (await tester.runAsync(
      () => issueSession.issues(issueTree, 0),
    ))!;
    expect(oldIssues.items.single.category, 'number-gap');
    final issuesCaptureKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: RepaintBoundary(
              key: issuesCaptureKey,
              child: ColoredBox(
                color: Desk.light.canvas,
                child: ChaptersPage(
                  library: pagedLibrary,
                  bookId: issuesBook.id,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await chapterAction(() async {});
    await chapterAction(() => tester.tap(find.text('检查章节')));
    expect(find.text('有效稿上下文'), findsOneWidget);
    expect(find.text('原稿对照'), findsOneWidget);
    expect(find.textContaining('3: 第三章 终'), findsWidgets);
    await screenshot('effective-check', captureKey: issuesCaptureKey);
    await chapterAction(() => tester.tap(find.text('原始书稿')));
    expect(find.text('原稿上下文'), findsOneWidget);
    expect(find.text('章节编号跳跃，请核对原文或参考目录'), findsWidgets);
    expect(find.textContaining('3: 第三章 终'), findsOneWidget);
    await screenshot('original-check', captureKey: issuesCaptureKey);
    await tester.tap(find.byTooltip('审阅此项'));
    await settle();
    await chapterAction(() => tester.tap(find.text('本项已核实正常')));
    expect(find.text('审阅状态：已核实正常'), findsOneWidget);
    await tester.runAsync(() async {
      await expectLater(
        issueSession.reviewIssue(
          oldIssues,
          oldIssues.items.single.id,
          'ignored',
        ),
        throwsFormatException,
      );
      final reviewed = await issueSession.issues(issueTree, 0);
      expect(reviewed.total, 1, reason: 'review must not erase a diagnostic');
      expect(reviewed.items.single.decision, 'confirmed_normal');
      final project =
          '${root.absolute.parent.path}/paging-probe/review-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
      expect((await pagedLibrary.saveProject(project)).succeeded, isTrue);
      final restored = LegacyLibraryAdapter();
      try {
        expect((await restored.openProject(project)).succeeded, isTrue);
        final session = restored.openChapters(issuesBook.id);
        final report = await session.issues(await session.read(0), 0);
        expect(report.items.single.decision, 'confirmed_normal');
      } finally {
        restored.dispose();
      }
      final effectiveBefore = await issueSession.issues(
        issueTree,
        0,
        effective: true,
      );
      expect(effectiveBefore.items.single.category, 'number-gap');
      expect(effectiveBefore.items.single.decision, isNull);
      await expectLater(
        issueSession.reviewIssue(
          effectiveBefore,
          effectiveBefore.items.single.id,
          'ignored',
        ),
        throwsFormatException,
      );
      await issueSession.rename(issueTree, issueTree.nodes.last.id, '第二章 终');
      await expectLater(
        issueSession.issueSource(effectiveBefore, effectiveBefore.items.single),
        throwsFormatException,
      );
      final currentTree = await issueSession.read(0);
      expect(
        (await issueSession.issues(currentTree, 0, effective: true)).total,
        0,
      );
      expect((await issueSession.issues(currentTree, 0)).total, 1);

      await expectLater(
        issueSession.reviewIssue(reviewed, reviewed.items.single.id, 'ignored'),
        throwsFormatException,
      );
    });
    await chapterAction(() => tester.tap(find.text('刷新结构')));
    expect(find.text('原稿上下文'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('当前草稿')));
    expect(find.text('当前规则未发现章节问题'), findsOneWidget);
    await screenshot('effective-recheck-clean', captureKey: issuesCaptureKey);
    expect(await tester.runAsync(issuesSource.readAsString), issuesText);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    final repairSource = File(
      '${root.absolute.parent.path}/paging-probe/repair.txt',
    );
    const repairText = '第一章 甲\n\n第一章 甲\n唯一正文\n第三章 丙\n丙文\n';
    await tester.runAsync(() async {
      await repairSource.writeAsString(repairText);
      expect(
        (await pagedLibrary.importFiles([repairSource.path])).single.succeeded,
        isTrue,
      );
    });
    final repairBook = pagedLibrary.books.value.firstWhere(
      (b) => b.path == repairSource.path,
    );
    pagedLibrary.selectBook(repairBook.id);
    final repairCapture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: repairCapture,
        child: RewriteApp(
          library: pagedLibrary,
          picker: _Picker(repairSource.path),
        ),
      ),
    );
    await settle();
    await chapterAction(() => tester.tap(find.text('章节').first));
    await chapterAction(() => tester.tap(find.text('一键修复')));
    expect(
      find.text('找到 1 项安全修复候选'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' | '),
    );
    await screenshot('repair-auto', captureKey: repairCapture);
    final repairSession = pagedLibrary.openChapters(repairBook.id);
    final unrepaired = (await tester.runAsync(() => repairSession.read(0)))!;
    expect(unrepaired.total, 3);
    await chapterAction(() => tester.tap(find.text('查看完整差异')));
    expect((await tester.runAsync(() => repairSession.read(0)))!.total, 3);
    await screenshot('repair-diff', captureKey: repairCapture);
    await chapterAction(() => tester.tap(find.text('浏览完整结构与正文')));
    expect(find.text('修复前后核对'), findsOneWidget);
    expect(find.text('共 2 节点'), findsOneWidget);
    expect(find.text('唯一正文'), findsOneWidget);
    expect(find.text('确认写入草稿'), findsNothing);
    await chapterAction(() => tester.tap(find.text('修改前').last));
    expect(find.text('共 3 节点'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('返回修复差异')));
    expect((await tester.runAsync(() => repairSession.read(0)))!.total, 3);
    await chapterAction(() => tester.tap(find.text('确认应用并复查')));
    expect(find.text('已应用 1 项修复，并完成复查'), findsOneWidget);
    final repaired = (await tester.runAsync(() => repairSession.read(0)))!;
    expect(repaired.total, 2);
    expect(repaired.nodes.first.id, unrepaired.nodes.first.id);
    expect(
      (await tester.runAsync(
        () => repairSession.body(repaired, repaired.nodes.first.id, 0),
      ))!.lines,
      contains('唯一正文'),
    );
    final afterRepair = (await tester.runAsync(
      () => repairSession.issues(repaired, 0, effective: true),
    ))!;
    expect(afterRepair.items.single.category, 'number-gap');
    await screenshot('repair-result', captureKey: repairCapture);
    expect(find.text('复查结果'), findsOneWidget);
    expect(find.text('本次已完成'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('查看依据')));
    expect(find.text('需要人工核对'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('返回复查结果')));
    expect(find.text('已应用 1 项修复，并完成复查'), findsOneWidget);
    await tester.runAsync(() async {
      final project =
          '${root.absolute.parent.path}/paging-probe/repair-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
      expect((await pagedLibrary.saveProject(project)).succeeded, isTrue);
      final reopened = LegacyLibraryAdapter();
      try {
        expect((await reopened.openProject(project)).succeeded, isTrue);
        final session = reopened.openChapters(repairBook.id);
        final tree = await session.read(0);
        expect(tree.total, 2);
        expect(tree.nodes.first.id, unrepaired.nodes.first.id);
        expect(
          (await session.issues(
            tree,
            0,
            effective: true,
          )).items.single.category,
          'number-gap',
        );
      } finally {
        reopened.dispose();
      }
    });
    await chapterAction(() => tester.tap(find.text('撤销本次修复')));
    expect((await tester.runAsync(() => repairSession.read(0)))!.total, 3);
    await chapterAction(() => tester.tap(find.text('按提示修复')));
    await screenshot('repair-guided', captureKey: repairCapture);
    // The diagnostic queue can order a numbering gap before its duplicate.
    if (find.text('采用建议 · 查看差异').evaluate().isEmpty) {
      await chapterAction(() => tester.tap(find.text('暂不处理')));
    }
    expect(find.text('采用建议 · 查看差异'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('正文对照')));
    expect(find.text('同名章节 · 正文对照'), findsOneWidget);
    expect(find.textContaining('唯一正文'), findsWidgets);
    expect(find.byType(DropdownButton<String>), findsNWidgets(2));
    await screenshot('compare', captureKey: repairCapture);
    await chapterAction(() => tester.tap(find.byTooltip('关闭正文对照')));
    expect((await tester.runAsync(() => repairSession.read(0)))!.total, 3);
    await chapterAction(() => tester.tap(find.text('采用建议 · 查看差异')));
    expect((await tester.runAsync(() => repairSession.read(0)))!.total, 3);
    await chapterAction(() => tester.tap(find.text('返回调整')));
    await chapterAction(() => tester.tap(find.text('返回章节').first));
    expect((await tester.runAsync(() => repairSession.read(0)))!.total, 3);
    await chapterAction(() => tester.tap(find.text('按提示修复')));
    if (find.text('采用建议 · 查看差异').evaluate().isNotEmpty) {
      await chapterAction(() => tester.tap(find.text('暂不处理')));
    }
    await chapterAction(() => tester.tap(find.text('打开章节核对')));
    expect(find.text('章节树'), findsOneWidget);
    expect(
      find.text('丙文'),
      findsOneWidget,
      reason: 'guided repair must navigate to the linked chapter and body',
    );
    await tester.runAsync(() async {
      final current = await repairSession.read(0);
      final choices = await repairSession.repairs(current);
      final candidate = await repairSession.previewRepairs(choices, {
        choices.changes.single.id,
      });
      await repairSession.confirm(candidate.preview);
      await expectLater(
        repairSession.confirm(candidate.preview),
        throwsFormatException,
      );
      await expectLater(
        repairSession.previewRepairs(choices, {choices.changes.single.id}),
        throwsFormatException,
      );
      final edited = await repairSession.read(0);
      await repairSession.rename(edited, edited.nodes.last.id, '第三章 新标题');
      await expectLater(
        repairSession.undoConfirmed(candidate.preview),
        throwsFormatException,
      );
    });
    expect(await tester.runAsync(repairSource.readAsString), repairText);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      final tree = await repairSession.read(0);
      await repairSession.rename(tree, tree.nodes.last.id, '第二章 丙');
    });
    pagedLibrary.selectBook(repairBook.id);
    final cleanCapture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: cleanCapture,
        child: RewriteApp(
          library: pagedLibrary,
          picker: _Picker(repairSource.path),
        ),
      ),
    );
    await settle();
    await chapterAction(() => tester.tap(find.text('章节').first));
    await chapterAction(() => tester.tap(find.text('一键修复')));
    expect(find.text('未发现需要处理的章节问题'), findsOneWidget);
    expect(find.text('2 个有效结构节点'), findsOneWidget);
    expect(find.text('查看完整差异'), findsNothing);
    await screenshot('repair-clean', captureKey: cleanCapture);
    await tester.runAsync(() async {
      final tree = await repairSession.read(0);
      await repairSession.rename(tree, tree.nodes.last.id, '第三章 丙');
    });
    await chapterAction(() => tester.tap(find.text('重新检测')));
    expect(find.text('未发现需要处理的章节问题'), findsNothing);
    expect(find.text('找到 0 项安全修复候选'), findsOneWidget);
    expect(find.text('1 项保留待核对'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('返回章节').first));
    await chapterAction(() => tester.tap(find.text('依据目录修复')));
    await chapterAction(() => tester.tap(find.text('获取参考目录')));
    await screenshot('catalog-source-dialog', captureKey: cleanCapture);
    await chapterAction(() => tester.tap(find.text('粘贴目录')));
    await tester.enterText(
      find.widgetWithText(TextField, '粘贴目录文本'),
      '第一章 甲\n第二章 丙',
    );
    await settle();
    await chapterAction(() => tester.tap(find.text('获取目录')));
    expect(find.text('预览目录'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('预览目录')));
    expect(find.text('第一章 甲'), findsOneWidget);
    expect(find.text('第二章 丙'), findsOneWidget);
    final catalogSession = pagedLibrary.openCatalog(repairBook.id);
    expect(catalogSession.saved, isNull);
    await chapterAction(() => tester.tap(find.text('已核对书名、作者、来源和目录范围')));
    await chapterAction(() => tester.tap(find.text('保存目录快照')));
    expect(find.text('本书目录快照已保存'), findsOneWidget);
    expect(catalogSession.saved!.entries.length, 2);
    await chapterAction(() => tester.tap(find.text('更换来源')));
    await chapterAction(() => tester.tap(find.text('取消')));
    expect(find.text('本书目录快照已保存'), findsOneWidget);
    expect(catalogSession.saved!.entries.length, 2);
    await screenshot('catalog-source', captureKey: cleanCapture);
    await tester.runAsync(() async {
      await expectLater(
        catalogSession.preview(catalogSession.saved!, identityConfirmed: false),
        throwsFormatException,
      );
    });
    await chapterAction(() => tester.tap(find.text('已核对书名、作者、来源和目录范围')));
    await chapterAction(() => tester.tap(find.text('生成原稿对齐预览')));
    expect(find.text('目录与原始书稿对应'), findsOneWidget);
    expect(find.text('原稿对齐预览'), findsOneWidget);
    expect(find.text('本地重复标题，正文未删除'), findsOneWidget);
    await screenshot('catalog-alignment', captureKey: cleanCapture);
    final searchField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '搜索参考标题或本地章节',
    );
    await tester.enterText(searchField, '重复');
    await settle();
    expect(find.text('显示 1 项 · 原稿坐标 · 未应用修改'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('本地重复标题，正文未删除')));
    expect(find.text('第 3 行'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('返回目录身份核对')));
    await tester.runAsync(() async {
      final project =
          '${root.absolute.parent.path}/paging-probe/catalog-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
      expect((await pagedLibrary.saveProject(project)).succeeded, isTrue);
      final reopened = LegacyLibraryAdapter();
      try {
        expect((await reopened.openProject(project)).succeeded, isTrue);
        expect(reopened.openCatalog(repairBook.id).saved!.entries.length, 2);
      } finally {
        reopened.dispose();
      }
      final candidate = await catalogSession.acquire('paste', '第一章 甲\n第二章 丙');
      final tree = await repairSession.read(0);
      await repairSession.rename(tree, tree.nodes.last.id, '第三章 新');
      expect(() => catalogSession.accept(candidate), throwsFormatException);
    });
    await chapterAction(() => tester.tap(find.text('更换来源')));
    await chapterAction(() => tester.tap(find.text('粘贴目录')));
    const ambiguousCatalog = '第一卷 起\n第一章 甲\n第二卷 续\n第一章 甲';
    await tester.enterText(
      find.widgetWithText(TextField, '粘贴目录文本'),
      ambiguousCatalog,
    );
    await settle();
    await chapterAction(() => tester.tap(find.text('获取目录')));
    await chapterAction(() => tester.tap(find.text('预览目录')));
    await chapterAction(() => tester.tap(find.text('已核对书名、作者、来源和目录范围')));
    await chapterAction(() => tester.tap(find.text('生成原稿对齐预览')));
    expect(find.text('跨卷同名，需选择对应'), findsNWidgets(2));
    await chapterAction(() => tester.tap(find.text('跨卷同名，需选择对应').first));
    await chapterAction(
      () => tester.tap(find.byType(DropdownButtonFormField<String>)),
    );
    await chapterAction(() => tester.tap(find.text('第一卷 起 · 第一章 甲').last));
    expect(find.text('清除人工对应'), findsOneWidget);
    expect(find.text('跨卷同名，需选择对应'), findsOneWidget);
    await screenshot('catalog-choice', captureKey: cleanCapture);
    await chapterAction(() => tester.tap(find.text('清除人工对应')));
    expect(find.text('跨卷同名，需选择对应'), findsNWidgets(3));
    await tester.runAsync(() async {
      final checkSession = pagedLibrary.openCatalog(repairBook.id);
      final candidate = await checkSession.acquire('paste', ambiguousCatalog);
      final plan = await checkSession.preview(
        candidate,
        identityConfirmed: true,
      );
      final row = plan.rows.firstWhere((r) => r.candidates.isNotEmpty);
      expect(await checkSession.evidence(plan, row), contains('唯一正文'));
      await expectLater(
        checkSession.choose(plan, row.line!, 'invalid'),
        throwsFormatException,
      );
      final next = await checkSession.choose(
        plan,
        row.line!,
        row.candidates.first.id,
      );
      await expectLater(
        checkSession.evidence(plan, row),
        throwsFormatException,
      );
      final nextRow = next.rows.firstWhere((r) => r.line == row.line);
      expect(await checkSession.evidence(next, nextRow), contains('唯一正文'));
      await expectLater(
        checkSession.choose(plan, row.line!, null),
        throwsFormatException,
      );
      checkSession.cancel();
      await expectLater(
        checkSession.evidence(next, nextRow),
        throwsFormatException,
      );
      await expectLater(
        checkSession.choose(next, row.line!, null),
        throwsFormatException,
      );
    });
    expect(await tester.runAsync(repairSource.readAsString), repairText);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    final staleSource = File(
      '${root.absolute.parent.path}/paging-probe/stale-repair.txt',
    );
    await tester.runAsync(() async {
      await staleSource.writeAsString(repairText);
      expect(
        (await pagedLibrary.importFiles([staleSource.path])).single.succeeded,
        isTrue,
      );
    });
    final staleBook = pagedLibrary.books.value.firstWhere(
      (b) => b.path == staleSource.path,
    );
    pagedLibrary.selectBook(staleBook.id);
    final staleCapture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: staleCapture,
        child: RewriteApp(
          library: pagedLibrary,
          picker: _Picker(staleSource.path),
        ),
      ),
    );
    await settle();
    await chapterAction(() => tester.tap(find.text('章节').first));
    await chapterAction(() => tester.tap(find.text('一键修复')));
    await chapterAction(() => tester.tap(find.text('查看完整差异')));
    final otherSession = pagedLibrary.openChapters(staleBook.id);
    await tester.runAsync(() async {
      final tree = await otherSession.read(0);
      await otherSession.rename(tree, tree.nodes.last.id, '第二章 丙');
    });
    await chapterAction(() => tester.tap(find.text('确认应用并复查')));
    expect(find.text('修复方案已过期'), findsOneWidget);
    expect(find.text('确认应用并复查'), findsNothing);
    expect((await tester.runAsync(() => otherSession.read(0)))!.total, 3);
    await screenshot('repair-stale', captureKey: staleCapture);
    await chapterAction(() => tester.tap(find.text('重新检测并生成方案')));
    expect(find.text('修复方案已过期'), findsNothing);
    expect(find.text('找到 1 项安全修复候选'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('查看完整差异')));
    await chapterAction(() => tester.tap(find.text('确认应用并复查')));
    expect(find.text('仍有 0 项待核对'), findsOneWidget);
    expect((await tester.runAsync(() => otherSession.read(0)))!.total, 2);
    expect(await tester.runAsync(staleSource.readAsString), repairText);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    final manySource = File(
      '${root.absolute.parent.path}/paging-probe/many-issues.txt',
    );
    final manyText = List.generate(
      121,
      (i) => '第${i * 2 + 1}章 章节$i\n正文$i\n',
    ).join();
    await tester.runAsync(() async {
      await manySource.writeAsString(manyText);
      expect(
        (await pagedLibrary.importFiles([manySource.path])).single.succeeded,
        isTrue,
      );
    });
    final manyBook = pagedLibrary.books.value.firstWhere(
      (b) => b.path == manySource.path,
    );
    final manySession = pagedLibrary.openChapters(manyBook.id);
    final manyTree = (await tester.runAsync(() => manySession.read(0)))!;
    final manyReport = (await tester.runAsync(
      () => manySession.issues(manyTree, 0, effective: true),
    ))!;
    expect(manyReport.total, 120);
    ChapterIssue? inspected;
    ChapterIssuePage? inspectedPage;
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: RepairIssueList(
            session: manySession,
            structure: manyTree,
            initial: manyReport,
            onInspect: (page, issue) {
              inspectedPage = page;
              inspected = issue;
            },
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await settle();
    final issueScroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('repair-result-issues')),
        matching: find.byType(Scrollable),
      ),
    );
    issueScroll.position.jumpTo(issueScroll.position.maxScrollExtent);
    await chapterAction(() => tester.pump());
    expect(find.text('正在读取问题…'), findsNothing);
    await chapterAction(() => tester.tap(find.text('查看依据').last));
    expect(inspectedPage!.offset, 100);
    expect(inspected!.evidence, contains('241'));
    final evidence = (await tester.runAsync(
      () => manySession.issueSource(inspectedPage!, inspected!),
    ))!;
    expect(evidence, contains('正文120'));
    issueScroll.position.jumpTo(0);
    await chapterAction(() => tester.pump());
    await chapterAction(() => tester.tap(find.text('查看依据').first));
    expect(inspectedPage!.offset, 0);
    await tester.runAsync(
      () => manySession.rename(manyTree, manyTree.nodes.first.id, '第一章 新标题'),
    );
    // The middle page was not fetched before the draft changed.
    issueScroll.position.jumpTo(60 * 200);
    await chapterAction(() => tester.pump());
    expect(find.text('重试加载问题'), findsWidgets);
    expect(find.text('正在读取问题…'), findsNothing);
    expect(find.text('查看依据'), findsNothing);
    expect(await tester.runAsync(manySource.readAsString), manyText);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    final comparisonSource = File('${root.absolute.path}/正文对照.txt');
    final comparisonText =
        '第一章 同名\n${List.generate(65, (i) => '左侧正文$i').join('\n')}\n第一章 同名\n右侧独立正文\n';
    await tester.runAsync(() async {
      await comparisonSource.writeAsString(comparisonText);
      expect(
        (await pagedLibrary.importFiles([comparisonSource.path]))
            .single
            .succeeded,
        isTrue,
      );
    });
    final comparisonBook = pagedLibrary.books.value.firstWhere(
      (b) => b.path == comparisonSource.path,
    );
    final comparisonSession = pagedLibrary.openChapters(comparisonBook.id);
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChaptersPage(library: pagedLibrary, bookId: comparisonBook.id),
        ),
      ),
    );
    await chapterAction(() async {});
    await chapterAction(() => tester.tap(find.text('更多')));
    await chapterAction(() => tester.tap(find.text('正文对照')));
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.textContaining('左侧正文0'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('右侧独立正文'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('下一段').first));
    expect(find.textContaining('左侧正文40'), findsOneWidget);
    expect(find.textContaining('右侧独立正文'), findsOneWidget);
    await chapterAction(() => tester.tap(find.text('下一段').first));
    expect(find.textContaining('左侧正文64'), findsOneWidget);
    await chapterAction(() => tester.tap(find.byTooltip('关闭正文对照')));
    expect((await tester.runAsync(() => comparisonSession.read(0)))!.total, 2);
    expect(
      await tester.runAsync(comparisonSource.readAsString),
      comparisonText,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
