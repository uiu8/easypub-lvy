import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/cleanup/batch_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'failed target can be excluded explicitly and successful batch survives undo reopen and EPUB',
    (t) async {
      t.view.physicalSize = const Size(1100, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late String root;
      final ids = <String>[];
      const original = '第一章 夜渡\n甲文  \n乙文  \n';
      final template = jsonEncode({
        'kind': 'cleanup',
        'pipeline': [
          {'kind': 'literal_replace', 'find': '乙文', 'replace': '丙文'},
        ],
      });
      late String before, blocked;
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        root = (await Directory('../artifacts').createTemp('cleanup-batch75-'))
            .absolute
            .path;
        state = PrototypeState(settingsDirectory: '$root/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        for (final name in ['甲书', '乙书']) {
          final f = File('$root/$name.txt')..writeAsStringSync(original);
          expect((await library.importFiles([f.path])).single.succeeded, true);
          ids.add(state.currentId);
        }
        final initial = library.openCleanupBatch(ids.first);
        try {
          final p = await initial.preview(
            jsonEncode({
              'kind': 'cleanup',
              'pipeline': [
                {'kind': 'trim_trailing_spaces'},
              ],
            }),
            ids,
            append: false,
          );
          await initial.apply(p);
        } finally {
          initial.dispose();
        }
        // V17 起只改名的书能逐本换算，不再失败（CLEAN-104）。这里用仍不支持的情况：
        // 章节修改压缩了两次（检查点之上又压缩），批量预览如实标为失败。
        final chapters = library.openChapters(ids.last);
        final tree = await chapters.read(0);
        await chapters.rename(tree, tree.nodes.first.id, '第一章 新夜渡');
        Future<void> compress() async => chapters.confirm(
          await (chapters as ChapterCheckpointSession).previewCheckpoint(
            await chapters.read(0),
          ),
        );
        await compress();
        final again = await chapters.read(0);
        await chapters.rename(again, again.nodes.first.id, '第一章 再渡');
        await compress();
        before = jsonEncode(state.cleanup.drafts);
        blocked = jsonEncode(state.cleanup.drafts[ids.last]);
        for (final id in ids) {
          library.checkBook(id, true);
        }
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      Future<void> settle() async {
        for (var i = 0; i < 400; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
            await t.pumpAndSettle();
            return;
          }
        }
        fail('batch still busy');
      }

      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<Set<String>>(
                  context: context,
                  builder: (_) => CleanupBatchDialog(
                    library: library,
                    bookId: ids.first,
                    template: template,
                  ),
                ),
                child: const Text('打开批量'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开批量'));
      await t.pumpAndSettle();
      await t.tap(find.text('追加到现有规则末尾'));
      await t.pumpAndSettle();
      await t.tap(find.text('替换现有规则').last);
      await t.pumpAndSettle();
      await t.tap(find.text('逐书预览'));
      await t.pump();
      await settle();
      t.view.physicalSize = const Size(900, 720);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('仅重新预览可处理书（1 本）'), findsOneWidget);
      await t.ensureVisible(find.text('仅重新预览可处理书（1 本）'));
      await t.pumpAndSettle();
      expect(state.cleanup.drafts, jsonDecode(before));
      await t.tap(find.text('仅重新预览可处理书（1 本）'));
      await t.pump();
      await settle();
      expect(find.text('不在本批次'), findsOneWidget);
      expect(state.cleanup.drafts, jsonDecode(before));
      expect(
        t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false,
      );
      await t.ensureVisible(find.text('已核对逐书预览，确认采用本批清理规则'));
      await t.pumpAndSettle();
      await t.tap(find.text('已核对逐书预览，确认采用本批清理规则'));
      await t.pump();
      await t.tap(find.text('确认采用'));
      await t.pump();
      await settle();
      expect(find.byType(CleanupBatchDialog), findsNothing);
      expect(state.cleanup.drafts[ids.last], jsonDecode(blocked));
      await t.runAsync(() async {
        final session = library.openCleanup(ids.first);
        try {
          final applied = jsonEncode(state.cleanup.drafts[ids.first]);
          await session.undo();
          expect(state.cleanup.drafts, jsonDecode(before));
          await session.redo();
          expect(state.cleanup.drafts[ids.first], jsonDecode(applied));
        } finally {
          session.dispose();
        }
        expect(
          (await library.saveProject('$root/batch.easypub.json')).succeeded,
          true,
        );
        expect(
          (await library.openProject('$root/batch.easypub.json')).succeeded,
          true,
        );
        expect(state.cleanup.drafts[ids.last], jsonDecode(blocked));
        final conversion = library.openConversion();
        try {
          final p = await conversion.preview(
            ConversionRequest(
              books: ids,
              directory: root,
              format: 'EPUB',
              runChecks: false,
            ),
          );
          expect(p.previewed, true);
          final outputs = await conversion.commit(p, acknowledgeWarnings: true);
          expect(outputs.length, 2);
          for (var i = 0; i < 2; i++) {
            expect(outputs[i].phase, 'complete', reason: outputs[i].detail);
            final result = await Process.run(
              Platform.environment['EASYPUB_TEST_PYTHON']!,
              [
                '-X',
                'utf8',
                '-c',
                "import sys,zipfile,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); b=E.fromstring(z.read('EPUB/body.xhtml')); n={'h':'http://www.w3.org/1999/xhtml'}; assert [x.text for x in b.findall('.//h:p',n)]==['　　'+v for v in sys.argv[2].splitlines()]; assert [x.text for x in b.findall('.//h:h1',n)]==[sys.argv[3]]",
                outputs[i].path,
                i == 0 ? '甲文  \n丙文  ' : '甲文\n乙文',
                i == 0 ? '第一章 夜渡' : '第一章 再渡',
              ],
            );
            expect(result.exitCode, 0, reason: result.stderr.toString());
          }
        } finally {
          conversion.dispose();
        }
        for (final name in ['甲书', '乙书']) {
          expect(File('$root/$name.txt').readAsStringSync(), original);
        }
      });
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
