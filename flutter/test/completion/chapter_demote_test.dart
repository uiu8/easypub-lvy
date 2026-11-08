import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/target_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'demote UI previews and cancels, preserves prose, undo redo and reopen',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late ChapterSession session;
      late File source;
      late String id, target, path;
      const original = '第一章 开始\n甲段。\n第二章 误识别\n乙段。\n第三章 结束\n丙段。\n';
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        final root = (await Directory(
          '../artifacts',
        ).createTemp('chapter-demote69-')).absolute;
        path = '${root.path}/saved.easypub.json';
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
        session = library.openChapters(id);
        target = (await session.read(0)).nodes[1].id;
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 300; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
          if (ready()) return;
        }
        fail('UI did not finish');
      }

      Future<void> idle() => waitFor(
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: ChapterWorkspace(
              library: library,
              bookId: id,
              initialNodeId: target,
            ),
          ),
        ),
      );
      await idle();
      Future<void> openPreview() async {
        await t.tap(find.byTooltip('更多章节操作'));
        await t.pumpAndSettle();
        await t.tap(find.text('标题改为正文（保留文字）'));
        await waitFor(
          () => find.byType(ChapterCandidateDialog).evaluate().isNotEmpty,
        );
        await idle();
        await t.pumpAndSettle();
      }

      await openPreview();
      await t.runAsync(() async {
        expect((await session.read(0)).total, 3);
      });
      expect(find.textContaining('仅取消所选行'), findsOneWidget);
      // Closing the review is cancellation: no state is published.
      Navigator.of(t.element(find.byType(ChapterCandidateDialog))).pop(false);
      await t.pumpAndSettle();
      await t.runAsync(() async {
        expect((await session.read(0)).total, 3);
      });
      await openPreview();
      await t.tap(find.text('确认写入草稿'));
      await waitFor(
        () => find.byType(ChapterCandidateDialog).evaluate().isEmpty,
      );
      await idle();
      await t.runAsync(() async {
        var tree = await session.read(0);
        expect(tree.nodes.map((n) => n.title), ['第一章 开始', '第三章 结束']);
        final body = (await session.body(
          tree,
          tree.nodes.first.id,
          0,
        )).lines.join('\n');
        expect(body, contains('第二章 误识别'));
        expect(body, contains('甲段。'));
        expect(body, contains('乙段。'));
        await session.history(tree, undo: true);
        tree = await session.read(0);
        expect(tree.nodes[1].id, target);
        await session.history(tree, undo: false);
        expect((await library.saveProject(path)).succeeded, true);
        expect((await library.openProject(path)).succeeded, true);
        session = library.openChapters(id);
        tree = await session.read(0);
        expect(tree.total, 2);
        expect(
          (await session.body(tree, tree.nodes.first.id, 0)).lines.join('\n'),
          body,
        );
        final stale = await session.preview(
          tree,
          DemoteChapterHeading(tree.nodes.last.id),
        );
        await session.history(tree, undo: true);
        await expectLater(
          session.confirm(stale),
          throwsA(isA<ChapterStateChanged>()),
        );
        expect((await session.read(0)).total, 3);
        expect(source.readAsStringSync(), original);
        // Removing the first heading retains its exact text in the prefix.
        tree = await session.read(0);
        final first = await session.preview(
          tree,
          DemoteChapterHeading(tree.nodes.first.id),
        );
        expect((await session.previewBody(first, r'$prefix', 0)).lines, [
          '第一章 开始',
          '甲段。',
        ]);
        await session.confirm(first);
        tree = await session.read(0);
        expect((await session.body(tree, r'$prefix', 0)).lines, [
          '第一章 开始',
          '甲段。',
        ]);
        expect(source.readAsStringSync(), original);
      });
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );
}
