import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/title_dialogs.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/split_dialog.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/target_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/dialogs.dart';

void main() {
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
  });
  testWidgets(
    'new volume and existing-line title use real previews, undo and reopen without losing prose',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late Directory root;
      late File source;
      late String id;
      const original = '第一章 起程\n甲段正文。\n隐藏章题\n乙段正文。\n第二章 归来\n尾段正文。\n';
      await t.runAsync(() async {
        root = (await Directory('../artifacts').createTemp('chapter-actions-'))
            .absolute;
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        source = File('${root.path}/样书.txt')..writeAsStringSync(original);
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        id = state.currentId;
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 300; i++) {
          await t.pump(const Duration(milliseconds: 20));
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
        }
        fail(
          'Chapter UI operation did not settle: ${t.widgetList<DeskNote>(find.byType(DeskNote)).map((n) => n.text).join(" / ")}',
        );
      }

      Future<void> idle() =>
          until(() => find.byType(LinearProgressIndicator).evaluate().isEmpty);
      final session = library.openChapters(id);
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: ChapterWorkspace(library: library, bookId: id),
          ),
        ),
      );
      await idle();
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('更多章节操作'));
      await t.pumpAndSettle();
      await t.tap(find.text('在本章前新增卷'));
      await t.pumpAndSettle();
      expect(find.byType(ChapterVolumeDialog), findsOneWidget);
      await t.enterText(
        find.byKey(const ValueKey('chapter-volume-input')),
        '第一卷 起程',
      );
      await t.pump();
      await t.tap(find.text('预览并确认'));
      await until(
        () => find.byType(ChapterCandidateDialog).evaluate().isNotEmpty,
      );
      await idle();
      await t.pumpAndSettle();
      await t.runAsync(() async {
        expect((await session.read(0)).total, 2);
      });
      await t.tap(find.text('确认写入草稿'));
      await until(() => find.byType(ChapterVolumeDialog).evaluate().isEmpty);
      await idle();
      await t.pumpAndSettle();
      await t.runAsync(() async {
        final tree = await session.read(0);
        expect(tree.nodes.first.role, 'volume');
        expect(tree.nodes[1].depth, 1);
        final first = tree.nodes.firstWhere((n) => n.title == '第一章 起程');
        expect(
          (await session.body(tree, first.id, 0)).lines.join('\n'),
          contains('甲段正文。'),
        );
      });
      await t.tap(find.byTooltip('更多章节操作'));
      await t.pumpAndSettle();
      await t.tap(find.text('正文行设为标题'));
      await until(() => find.byType(ChapterSplitDialog).evaluate().isNotEmpty);
      await idle();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('split-title')), findsNothing);
      await t.tap(find.text('隐藏章题').last);
      await t.pump();
      await t.pump();
      await t.tap(find.text('预览并确认'));
      await until(() => find.text('确认新增标题').evaluate().isNotEmpty);
      await idle();
      await t.pumpAndSettle();
      await t.runAsync(() async {
        expect((await session.read(0)).total, 3);
      });
      await t.tap(find.text('确认新增标题'));
      await until(() => find.byType(ChapterSplitDialog).evaluate().isEmpty);
      await idle();
      await t.pumpAndSettle();
      await t.runAsync(() async {
        var tree = await session.read(0);
        expect(tree.total, 4);
        final node = tree.nodes.singleWhere((n) => n.title == '隐藏章题');
        expect(node.depth, 1);
        expect(
          (await session.body(tree, node.id, 0)).lines.join('\n'),
          contains('乙段正文。'),
        );
        await session.history(tree, undo: true);
        tree = await session.read(0);
        expect(tree.total, 3);
        await session.history(tree, undo: false);
        tree = await session.read(0);
        expect(tree.total, 4);
        final stale = await session.preview(
          tree,
          InsertChapterVolume(tree.nodes.last.id, '第二卷'),
        );
        await session.history(tree, undo: true);
        await expectLater(
          session.confirm(stale),
          throwsA(isA<ChapterStateChanged>()),
        );
        await session.history(await session.read(0), undo: false);
        final path = '${root.path}/edited.easypub.json';
        expect((await library.saveProject(path)).succeeded, true);
        expect((await library.openProject(path)).succeeded, true);
        tree = await library.openChapters(id).read(0);
        expect(tree.total, 4);
        expect(tree.nodes.map((n) => n.title), [
          '第一卷 起程',
          '第一章 起程',
          '隐藏章题',
          '第二章 归来',
        ]);
        expect(source.readAsStringSync(), original);
      });
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );
  test('duplicate removal rejects nonduplicates and preserves text on valid repeated heading', () async {
    // Flutter test files run in separate isolates, but tests within one file share FRB.

    final root = (await Directory(
      '../artifacts',
    ).createTemp('chapter-duplicate-')).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    const text = '第一章 起程\n\n第一章 起程\n唯一正文。\n第二章 终\n尾文。\n';
    final source = File('${root.path}/重复.txt')..writeAsStringSync(text);
    expect((await library.importFiles([source.path])).single.succeeded, true);
    final session = library.openChapters(state.currentId);
    var tree = await session.read(0);
    await expectLater(
      session.preview(tree, RemoveDuplicateChapterHeading(tree.nodes.last.id)),
      throwsA(isA<FormatException>()),
    );
    expect((await session.read(0)).guard, tree.guard);
    final candidate = await session.preview(
      tree,
      RemoveDuplicateChapterHeading(tree.nodes[1].id),
    );
    expect((await session.read(0)).total, 3);
    await session.confirm(candidate);
    tree = await session.read(0);
    expect(tree.total, 2);
    expect(
      (await session.body(tree, tree.nodes.first.id, 0)).lines.join('\n'),
      contains('唯一正文。'),
    );
    await session.history(tree, undo: true);
    expect((await session.read(0)).total, 3);
    expect(source.readAsStringSync(), text);
  });
}
