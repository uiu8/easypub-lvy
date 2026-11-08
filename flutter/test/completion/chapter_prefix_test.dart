import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/split_dialog.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/target_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'heading-free book remains readable, can create a boundary and demote its last heading',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late ChapterSession session;
      late String id, path;
      late File source;
      const original = '开场说明。\n首段正文。\n转折标题\n后段正文。\n';
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        final root = (await Directory(
          '../artifacts',
        ).createTemp('chapter-prefix70-')).absolute;
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        source = File('${root.path}/无标题.txt')..writeAsStringSync(original);
        path = '${root.path}/saved.easypub.json';
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        id = state.currentId;
        session = library.openChapters(id);
        expect((await session.read(0)).total, 0);
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
        fail('Prefix UI did not settle');
      }

      Future<void> idle() => waitFor(
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      Future<void> mount() async {
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
      }

      await mount();
      expect(find.text('首段正文。'), findsOneWidget);
      expect(find.byKey(const ValueKey('chapter-prefix')), findsOneWidget);
      await t.tap(find.text('正文行设为标题'));
      await waitFor(
        () => find.byType(ChapterSplitDialog).evaluate().isNotEmpty,
      );
      await idle();
      await t.pumpAndSettle();
      await t.tap(find.text('转折标题').last);
      await t.pump();
      await t.tap(find.text('预览并确认'));
      await waitFor(() => find.text('确认新增标题').evaluate().isNotEmpty);
      await idle();
      await t.pumpAndSettle();
      await t.tap(find.text('确认新增标题'));
      await waitFor(() => find.byType(ChapterSplitDialog).evaluate().isEmpty);
      await idle();
      await t.runAsync(() async {
        var tree = await session.read(0);
        expect(tree.nodes.single.title, '转折标题');
        expect((await session.body(tree, chapterPrefixNode.id, 0)).lines, [
          '开场说明。',
          '首段正文。',
        ]);
        expect((await session.body(tree, tree.nodes.single.id, 0)).lines, [
          '后段正文。',
        ]);
        await session.history(tree, undo: true);
        tree = await session.read(0);
        expect(tree.total, 0);
        expect(
          (await session.body(tree, chapterPrefixNode.id, 0)).lines.join('\n'),
          original.trimRight(),
        );
        await session.history(tree, undo: false);
        final saved = await library.saveProject(path);
        expect(saved.succeeded, true, reason: 'save: ${saved.message}');
        final opened = await library.openProject(path);
        expect(opened.succeeded, true, reason: 'open: ${opened.message}');
        session = library.openChapters(id);
      });
      await t.pumpWidget(const SizedBox());
      await mount();
      await t.tap(find.byTooltip('更多章节操作'));
      await t.pumpAndSettle();
      await t.tap(find.text('标题改为正文（保留文字）'));
      await waitFor(
        () => find.byType(ChapterCandidateDialog).evaluate().isNotEmpty,
      );
      await idle();
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ChapterCandidateDialog),
          matching: find.text('转折标题'),
        ),
        findsOneWidget,
      );
      await t.tap(find.text('确认写入草稿'));
      await waitFor(
        () => find.byType(ChapterCandidateDialog).evaluate().isEmpty,
      );
      await idle();
      await t.pumpAndSettle();
      expect(find.text('后段正文。'), findsOneWidget);
      expect(find.text('正文行设为标题'), findsOneWidget);
      await t.runAsync(() async {
        expect((await session.read(0)).total, 0);
        path = '$path.no-headings.easypub.json';
        final saved = await library.saveProject(path);
        expect(saved.succeeded, true, reason: 'save: ${saved.message}');
        final opened = await library.openProject(path);
        expect(opened.succeeded, true, reason: 'open: ${opened.message}');
        final reopened = library.openChapters(id);
        final tree = await reopened.read(0);
        expect(tree.total, 0);
        expect(
          (await reopened.body(tree, chapterPrefixNode.id, 0)).lines.join('\n'),
          original.trimRight(),
        );
        expect(source.readAsStringSync(), original);
      });
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );
}
