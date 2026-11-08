import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/cleanup/batch_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'batch cleanup previews all targets, retains ranges and applies atomically',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = PrototypeState();
      addTearDown(backend.dispose);
      final dir = Directory(
        '../artifacts/frontend-rewrite/cleanup-batch-probe',
      );
      const original = '第一章 夜渡\n甲文  \n乙文  \n';
      final ids = <String>[];
      final template = jsonEncode({
        'kind': 'cleanup',
        'pipeline': [
          {'kind': 'trim_trailing_spaces'},
        ],
      });
      await tester.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            File(
              Platform.environment['EASYPUB_TEST_DLL'] ??
                  '../target/release/easypub_bridge.dll',
            ).absolute.path,
          ),
        );
        await dir.create(recursive: true);
        for (final entry in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(entry.key)..addFont(
                File(entry.value)
                    .readAsBytes()
                    .then((bytes) => bytes.buffer.asByteData()),
              ))
              .load();
        }
        for (final name in ['批量甲', '批量乙']) {
          final file = File('${dir.path}/$name.txt');
          await file.writeAsString(original);
          await backend.importBookOutcome(file.absolute.path);
          ids.add(backend.currentId);
        }
      });
      final library = LegacyLibraryAdapter(backend: backend);
      addTearDown(library.dispose);
      final batch = library.openCleanupBatch(ids.first);
      addTearDown(batch.dispose);
      await tester.runAsync(() async {
        final second = library.openCleanup(ids.last);
        try {
          final plan = await second.preview(
            jsonEncode({
              'kind': 'cleanup',
              'pipeline': [
                {'kind': 'collapse_blank_lines'},
              ],
              'start_line': 3,
              'end_line': 3,
            }),
          );
          await second.apply(plan);
        } finally {
          second.dispose();
        }
        final before = jsonEncode(backend.cleanup.drafts);
        var plan = await batch.preview(template, ids, append: false);
        expect(plan.ready, isTrue);
        expect(plan.items.map((i) => i.changes), [2, 1]);
        expect(jsonEncode(backend.cleanup.drafts), before);
        batch.cancel();
        await expectLater(batch.apply(plan), throwsFormatException);
        plan = await batch.preview(template, ids, append: false);
        backend.change(() {
          backend.cleanup.drafts[ids.last]!['skip_lines'] = [3];
        });
        await expectLater(batch.apply(plan), throwsFormatException);
        expect(backend.cleanup.drafts.containsKey(ids.first), isFalse);
        backend.change(() {
          backend.cleanup.drafts[ids.last]!.remove('skip_lines');
        });
        plan = await batch.preview(template, ids, append: false);
        await batch.apply(plan);
        expect(backend.cleanup.drafts[ids.last]!['start_line'], 3);
        expect(backend.cleanup.drafts[ids.last]!['end_line'], 3);
        final state = jsonEncode(backend.cleanup.drafts);
        final bad = await batch.preview(
          jsonEncode({
            'kind': 'cleanup',
            'pipeline': [
              {'kind': 'regex_replace', 'pattern': '[', 'replace': ''},
            ],
          }),
          ids,
          append: false,
        );
        expect(bad.ready, isFalse);
        await expectLater(batch.apply(bad), throwsFormatException);
        expect(jsonEncode(backend.cleanup.drafts), state);
        final chapters = library.openChapters(ids.last);
        try {
          final tree = await chapters.read(0);
          await chapters.rename(tree, tree.nodes.first.id, '第一章 新夜渡');
          final conflict = await batch.preview(
            jsonEncode({
              'kind': 'cleanup',
              'pipeline': [
                {'kind': 'literal_replace', 'find': '乙文', 'replace': '丙文'},
              ],
            }),
            ids,
            append: false,
          );
          expect(conflict.items.first.error, isEmpty);
          expect(conflict.items.last.error, isNotEmpty);
          await expectLater(batch.apply(conflict), throwsFormatException);
          expect(jsonEncode(backend.cleanup.drafts), state);
        } finally {
          await chapters.history(await chapters.read(0), undo: true);
        }
        final undo = library.openCleanup(ids.first);
        try {
          await undo.undo();
          expect(backend.cleanup.drafts.containsKey(ids.first), isFalse);
        } finally {
          undo.dispose();
        }
      });
      for (final id in ids) {
        library.checkBook(id, true);
      }
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
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
                  child: const Text('批量入口'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('批量入口'));
      await tester.pumpAndSettle();
      expect(find.text('确认采用'), findsOneWidget);
      await tester.tap(find.text('逐书预览'));
      await tester.pump();
      for (
        var i = 0;
        i < 200 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('已核对逐书预览，确认采用本批清理规则'), findsOneWidget);
      expect(backend.cleanup.drafts.containsKey(ids.first), isFalse);
      await tester.tap(find.text('浏览全部差异').first);
      await tester.pump();
      for (
        var i = 0;
        i < 200 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('1–1 / 1 条'), findsOneWidget);
      await tester.tap(find.text('返回批量预览'));
      await tester.pumpAndSettle();
      expect(backend.cleanup.drafts.containsKey(ids.first), isFalse);
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/batch-preview.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('已核对逐书预览，确认采用本批清理规则'));
      await tester.pump();
      await tester.tap(find.text('确认采用'));
      await tester.pump();
      for (
        var i = 0;
        i < 200 && find.byType(CleanupBatchDialog).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(CleanupBatchDialog), findsNothing);
      expect(backend.cleanup.drafts.containsKey(ids.first), isTrue);
      await tester.runAsync(() async {
        final project = File(
          '${dir.path}/batch-${DateTime.now().microsecondsSinceEpoch}.easypub.json',
        ).absolute.path;
        final saved = jsonEncode(backend.cleanup.drafts);
        expect((await library.saveProject(project)).succeeded, isTrue);
        expect((await library.openProject(project)).succeeded, isTrue);
        expect(backend.cleanup.drafts, jsonDecode(saved));
        for (final name in ['批量甲', '批量乙']) {
          expect(await File('${dir.path}/$name.txt').readAsString(), original);
        }
      });
      expect(tester.takeException(), isNull);
    },
  );
}
