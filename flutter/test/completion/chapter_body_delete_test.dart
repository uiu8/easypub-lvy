import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/body_delete_dialog.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/target_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/dialogs.dart';

void main() {
  testWidgets(
    'cross-page body deletion previews, cancels, persists and exports exact remaining prose',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late ChapterSession session;
      late File source;
      late String root, id, original;
      final lines = List.generate(40, (i) => '独立正文${i + 1}。');
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        root = (await Directory('../artifacts').createTemp('chapter-delete71-'))
            .absolute
            .path;
        state = PrototypeState(settingsDirectory: '$root/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        original = '第一章 开始\n${lines.join('\n')}\n第二章 结束\n尾段。\n';
        source = File('$root/正文.txt')..writeAsStringSync(original);
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        id = state.currentId;
        session = library.openChapters(id);
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 400; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
          if (ready()) return;
        }
        fail(
          'Deletion UI did not settle: ${t.widgetList<DeskNote>(find.byType(DeskNote)).map((w) => w.text).join(' / ')}',
        );
      }

      Future<void> idle() => waitFor(
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
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
      expect(find.text('删除正文行'), findsNothing);
      await t.tap(find.byTooltip('更多章节操作'));
      await t.pumpAndSettle();
      await t.tap(find.text('删除正文行'));
      await waitFor(
        () => find.byType(ChapterBodyDeleteDialog).evaluate().isNotEmpty,
      );
      await idle();
      await t.pumpAndSettle();
      final list = find
          .descendant(
            of: find.byType(ChapterBodyDeleteDialog),
            matching: find.byType(Scrollable),
          )
          .first;
      final start = find.byKey(const ValueKey('delete-body-line-29'));
      await t.scrollUntilVisible(start, 400, scrollable: list);
      await t.tap(start);
      await t.pump();
      await t.tap(find.text('后 30 行'));
      await idle();
      await t.pumpAndSettle();
      final end = find.byKey(const ValueKey('delete-body-line-32'));
      await t.scrollUntilVisible(end, -200, scrollable: list);
      await t.tap(end);
      await t.pump();
      expect(find.textContaining('共 4 行'), findsOneWidget);
      await t.pumpAndSettle();
      await t.tap(find.text('预览删除'));
      await waitFor(
        () => find.byType(ChapterCandidateDialog).evaluate().isNotEmpty,
      );
      await idle();
      await t.pumpAndSettle();
      await t.runAsync(() async {
        final tree = await session.read(0);
        expect((await session.body(tree, tree.nodes.first.id, 0)).total, 40);
      });
      await t.tap(find.text('返回调整'));
      await waitFor(
        () => find.byType(ChapterCandidateDialog).evaluate().isEmpty,
      );
      await idle();
      await t.pumpAndSettle();
      expect(find.textContaining('共 4 行'), findsOneWidget);
      await t.pumpAndSettle();
      await t.tap(find.text('预览删除'));
      await waitFor(
        () => find.byType(ChapterCandidateDialog).evaluate().isNotEmpty,
      );
      await idle();
      await t.pumpAndSettle();
      await t.tap(find.text('确认写入草稿'));
      await waitFor(
        () => find.byType(ChapterBodyDeleteDialog).evaluate().isEmpty,
      );
      await idle();
      await t.pumpAndSettle();
      await t.runAsync(() async {
        var tree = await session.read(0);
        final nodeId = tree.nodes.first.id;
        expect((await session.body(tree, nodeId, 0)).total, 36);
        final expected = [...lines.take(28), ...lines.skip(32)];
        Future<List<String>> readBody() async {
          final p = await session.read(0);
          return [
            ...(await session.body(p, nodeId, 0)).lines,
            ...(await session.body(p, nodeId, 30)).lines,
          ];
        }

        expect(await readBody(), expected);
        await session.history(tree, undo: true);
        tree = await session.read(0);
        expect((await session.body(tree, nodeId, 0)).total, 40);
        await session.history(tree, undo: false);
        final saved = await library.saveProject('$root/deleted.easypub.json');
        expect(saved.succeeded, true, reason: saved.message);
        expect(
          (await library.openProject('$root/deleted.easypub.json')).succeeded,
          true,
        );
        session = library.openChapters(id);
        expect(await readBody(), expected);
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
          final output = (await conversion.commit(
            preview,
            acknowledgeWarnings: true,
          )).single;
          expect(output.phase, 'complete', reason: output.detail);
          final inspected = await Process.run(
            Platform.environment['EASYPUB_TEST_PYTHON']!,
            [
              '-X',
              'utf8',
              '-c',
              // 每章一个文件（V36，OUT-081）：按 spine 顺序读全部正文文件。
              r'''
import re,sys,zipfile,xml.etree.ElementTree as E
z=zipfile.ZipFile(sys.argv[1]); n={'h':'http://www.w3.org/1999/xhtml'}; o='{http://www.idpf.org/2007/opf}'
opf=E.fromstring(z.read('EPUB/package.opf'))
items={i.get('id'):i.get('href') for i in opf.iter(o+'item')}
hrefs=[items[r.get('idref')] for r in opf.iter(o+'itemref')]
docs=[E.fromstring(z.read('EPUB/'+h)) for h in hrefs if re.fullmatch(r'body(-\d{4})?\.xhtml',h)]
assert [x.text for b in docs for x in b.findall('.//h:p',n)]==['　　'+v for v in sys.argv[2].splitlines()]
assert [x.text for b in docs for x in b.findall('.//h:h1',n)]==['第一章 开始','第二章 结束']
''',
              output.path,
              [...expected, '尾段。'].join('\n'),
            ],
          );
          expect(inspected.exitCode, 0, reason: inspected.stderr.toString());
        } finally {
          conversion.dispose();
        }
        tree = await session.read(0);
        final stale = await session.preview(
          tree,
          ExcludeChapterBodyLines(nodeId, 1, 1),
        );
        await session.history(tree, undo: true);
        await expectLater(
          session.confirm(stale),
          throwsA(isA<ChapterStateChanged>()),
        );
        expect(source.readAsStringSync(), original);
      });
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );
}
