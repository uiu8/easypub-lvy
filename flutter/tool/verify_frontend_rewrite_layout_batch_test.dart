import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/layout/book_batch_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'legacy_state_helpers.dart';

void main() {
  testWidgets(
    'layout batch explicit fields, cancel, stale guard, commit and reopen',
    (tester) async {
      tester.view.physicalSize = const Size(900, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory('../artifacts/frontend-rewrite/layout-batch');
      final backend = PrototypeState(
        settingsDirectory: '${root.absolute.path}/settings',
      );
      addTearDown(backend.dispose);
      final ids = <String>[];
      const original = '第一章 来信\n河边来了一封信。   \n第二章 夜渡\n天色晚了。   \n';
      await tester.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            File(
              Platform.environment['EASYPUB_TEST_DLL'] ??
                  '../target/release/easypub_bridge.dll',
            ).absolute.path,
          ),
        );
        await root.create(recursive: true);
        for (final entry in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(entry.key)..addFont(
                File(entry.value).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
        for (final name in ['甲', '乙']) {
          final file = File('${root.path}/$name.txt');
          await file.writeAsString(original);
          await backend.importBookOutcome(file.absolute.path);
          ids.add(backend.currentId);
        }
      });
      final library = LegacyLibraryAdapter(backend: backend);
      addTearDown(library.dispose);
      late String before;
      await tester.runAsync(() async {
        final layout = library.openLayout(ids.first);
        await layout.apply(
          await layout.preview({
            'font_size': 24.0,
            'font_size_unit': 'px',
            'line_height': 2.0,
          }),
        );
        layout.dispose();
        before = jsonEncode(backend.production.settings(ids.last));
        final batch = library.openLayoutBatch(ids.first);
        await expectLater(batch.preview({'title'}, ids), throwsA(anything));
        expect(jsonEncode(backend.production.settings(ids.last)), before);
        await expectLater(
          batch.preview({'font_size'}, [ids.last, 'missing-book']),
          throwsA(anything),
        );
        expect(jsonEncode(backend.production.settings(ids.last)), before);
        batch.dispose();
        final oldCover = backend.draftFor(ids.last).coverPath;
        final firstBefore = jsonEncode(backend.production.settings(ids.first));
        backend.draftFor(ids.last).coverPath =
            '${root.absolute.path}/missing.png';
        final badResource = library.openLayoutBatch(ids.first);
        try {
          await expectLater(
            badResource.preview({'font_size'}, ids),
            throwsA(anything),
          );
          expect(
            jsonEncode(backend.production.settings(ids.first)),
            firstBefore,
          );
          expect(
            backend.production.settings(ids.last)['font_size'],
            (jsonDecode(before) as Map)['font_size'],
          );
        } finally {
          backend.draftFor(ids.last).coverPath = oldCover;
          badResource.dispose();
        }
        final staleSession = library.openLayoutBatch(ids.first);
        final stale = await staleSession.preview({'font_size'}, ids);
        final changed = library.openLayout(ids.last);
        await changed.apply(await changed.preview({'line_height': 1.9}));
        changed.dispose();
        final now = jsonEncode(backend.production.settings(ids.last));
        await expectLater(staleSession.apply(stale), throwsA(anything));
        expect(jsonEncode(backend.production.settings(ids.last)), now);
        staleSession.dispose();
        before = now;
        final cleaner = library.openCleanup(ids.first);
        await cleaner.apply(
          await cleaner.preview(
            jsonEncode({
              'kind': 'cleanup',
              'pipeline': [
                {'kind': 'trim_trailing_spaces'},
              ],
            }),
          ),
        );
        cleaner.dispose();
      });
      for (final id in ids) {
        library.checkBook(id, true);
      }
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        BookBatchDialog(library: library, bookId: ids.first),
                  ),
                  child: const Text('打开批量'),
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1.5);
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('${root.path}/$name.png')
                .writeAsBytes(data!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      Future<void> waitFor(bool Function() ready) async {
        for (var n = 0; n < 200 && !ready(); n++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(ready(), true);
      }

      Future<void> prepare() async {
        await tester.tap(find.text('打开批量'));
        await tester.pumpAndSettle();
        expect(find.textContaining('来源：'), findsOneWidget);
        await screenshot('selection');
        await tester.tap(find.text('选择字段（0）'));
        await tester.pumpAndSettle();
        await screenshot('fields');
        await tester.scrollUntilVisible(
          find.text('字号'),
          200,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text('字号'));
        await tester.pump();
        await tester.tap(find.text('采用所选字段'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清理规则'));
        await tester.pump();
        await tester.tap(find.text('预览并确认'));
        await tester.pump();
        await waitFor(() => find.text('确认应用').evaluate().isNotEmpty);
      }

      final oldCover = backend.draftFor(ids.last).coverPath;
      backend.draftFor(ids.last).coverPath =
          '${root.absolute.path}/missing.png';
      await prepare();
      expect(find.text('未通过'), findsOneWidget);
      await screenshot('blocked');
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '确认应用'))
            .onPressed,
        isNull,
      );
      expect(backend.cleanup.drafts[ids.last], isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      backend.draftFor(ids.last).coverPath = oldCover;
      await prepare();
      await screenshot('ready');
      await tester.tap(find.byTooltip('查看变更详情').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('查看全部清理差异').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看全部清理差异').first);
      await tester.pump();
      await waitFor(() => find.text('1–2 / 2 条').evaluate().isNotEmpty);
      await tester.tap(find.text('返回批量预览'));
      await tester.pumpAndSettle();
      expect(jsonEncode(backend.production.settings(ids.last)), before);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(jsonEncode(backend.production.settings(ids.last)), before);
      await prepare();
      await tester.tap(find.text('确认应用'));
      await tester.pump();
      await waitFor(
        () => backend.production.settings(ids.last)['font_size'] == 24.0,
      );
      await tester.pumpAndSettle();
      expect(backend.production.settings(ids.last)['line_height'], 1.9);
      expect(backend.cleanup.drafts[ids.last], isNotNull);
      expect(
        backend.production.settings(ids.last)['title'],
        (jsonDecode(before) as Map)['title'],
      );
      await tester.runAsync(() async {
        final project =
            '${root.absolute.path}/batch-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
        expect(await backend.saveProjectOutcome(project), true);
        expect(await backend.openProjectOutcome(project), true);
        final real = backend.shelf.books.where((b) => !b.isDemo).toList();
        expect(real.length, 2);
        for (final b in real) {
          expect(backend.production.settings(b.id)['font_size'], 24.0);
        }
        for (final name in ['甲', '乙']) {
          expect(await File('${root.path}/$name.txt').readAsString(), original);
        }
      });
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
