import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/chapters/chapter_view_state.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'issue workspace previews, cancels, applies and undoes an old-project prose-heading repair with full Unicode paging',
    (t) async {
      t.view.physicalSize = const Size(1050, 820);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState backend;
      late LegacyLibraryAdapter library;
      late ChapterSession chapters;
      late String id;
      late File source;
      final longLine = '${'长😀段落' * 650}长行终点';
      final original =
          '第一章 开始\n甲段正文。\n第一节课是历史。\n乙段正文。\n$longLine\n${List.generate(95, (i) => '段落$i').join('\n')}\n第三章 结束\n丙段正文。\n';
      await t.runAsync(() async {
        for (final font in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(font.key)..addFont(
                File(font.value)
                    .readAsBytes()
                    .then((bytes) => bytes.buffer.asByteData()),
              ))
              .load();
        }
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        final root = (await Directory(
          '../artifacts',
        ).createTemp('issue-preview-')).absolute;
        backend = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: backend);
        await library.load();
        await library.savePatch({'check_after_import': false});
        source = File('${root.path}/样书.txt')..writeAsStringSync(original);
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        id = backend.currentId;
        // Model an old saved project: new imports already reject this prose heading.
        final imported = backend.shelf.books
            .firstWhere((book) => book.id == id)
            .source!;
        backend.change(() {
          backend.manuscript.structures[id] = {
            'source_id': imported.sourceId,
            'revision': 1,
            'overrides': [],
          };
          backend.manuscript.structureHistories.remove(id);
        });
        chapters = library.openChapters(id);
        final report = await chapters.issues(
          await chapters.read(0),
          0,
          effective: true,
        );
        final issue = report.items.firstWhere(
          (item) => item.category == 'prose-heading',
        );
        final options = await (chapters as TargetedChapterRepairSession)
            .repairsForIssue(await chapters.read(0), issue.id);
        final change = options.changes.first;
        final plan = await chapters.previewRepairs(options, {change.id});
        final comparisons = chapters as ChapterRepairComparisonSession;
        var pair = await comparisons.previewComparison(plan, change);
        expect(pair.before.nodes.map((n) => n.title), contains('第一节课是历史。'));
        expect(
          pair.after.nodes.map((n) => n.title),
          isNot(contains('第一节课是历史。')),
        );
        final afterRows = <ChapterContextRow>[...pair.after.rows];
        while (pair.after.nextOffset != null) {
          pair = await comparisons.previewComparison(
            plan,
            change,
            afterOffset: pair.after.nextOffset!,
            afterCharOffset: pair.after.nextCharOffset,
          );
          afterRows.addAll(pair.after.rows);
        }
        expect(
          afterRows.where((r) => r.line == 5).map((r) => r.text).join(),
          longLine,
        );
        expect(afterRows.any((r) => r.text == '段落94'), true);
        expect((await chapters.read(0)).total, 3);
      });
      addTearDown(() {
        library.dispose();
        backend.dispose();
      });
      Future<void> settle() async {
        for (var i = 0; i < 300; i++) {
          await t.pump(const Duration(milliseconds: 20));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (i > 8 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            return;
          }
        }
        fail('Issue repair did not finish');
      }

      final view = ChapterViewState()..issues.category = 'prose-heading';
      final capture = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(),
            home: Scaffold(
              body: ChapterWorkspace(
                library: library,
                bookId: id,
                initialIssues: true,
                viewState: view,
              ),
            ),
          ),
        ),
      );
      await settle();
      expect(find.text('修改前'), findsOneWidget);
      expect(find.text('修改后'), findsOneWidget);
      await t.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '../artifacts/chapter-workspace-20261009/actual-repair-preview.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(find.text('甲段正文。', findRichText: true), findsWidgets);
      expect(find.text('乙段正文。', findRichText: true), findsWidgets);
      expect(find.textContaining('目录中的标题：'), findsNothing);
      await t.tap(find.text('取消预览'));
      await settle();
      await t.runAsync(() async => expect((await chapters.read(0)).total, 3));
      await t.tap(find.text('预览处理'));
      await settle();
      await t.tap(find.text('应用修改'));
      await settle();
      await t.runAsync(() async {
        final tree = await chapters.read(0);
        expect(tree.total, 2);
        expect(
          (await chapters.body(tree, tree.nodes.first.id, 0)).lines.join('\n'),
          contains('第一节课是历史。\n乙段正文。'),
        );
        expect(source.readAsStringSync(), original);
      });
      await t.tap(find.text('正文').first);
      await settle();
      await t.tap(find.byKey(const ValueKey('chapter-undo')));
      await settle();
      await t.runAsync(() async {
        expect(
          (await chapters.read(0)).nodes.map((n) => n.title),
          contains('第一节课是历史。'),
        );
        expect(source.readAsStringSync(), original);
      });
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
