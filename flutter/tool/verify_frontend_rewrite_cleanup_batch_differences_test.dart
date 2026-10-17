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
import 'package:easypub_desktop/desk/cleanup/batch_difference_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'batch differences page every change and candidate; stale and cancelled reads reject',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = PrototypeState();
      addTearDown(backend.dispose);
      final dir = Directory(
        '../artifacts/frontend-rewrite/cleanup-batch-differences-probe',
      );
      final source = File('${dir.path}/分页清理.txt');
      final original =
          '第一章 夜渡\n${List.generate(85, (i) => '正文${i + 1}  ').join('\n')}\n'
          '${List.generate(45, (i) => '请收藏').join('\n')}\n';
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
        await source.writeAsString(original);
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
        await backend.importBookOutcome(source.absolute.path);
      });
      final library = LegacyLibraryAdapter(backend: backend);
      addTearDown(library.dispose);
      final id = backend.currentId;
      final session = library.openCleanupBatch(id);
      addTearDown(session.dispose);
      final template = jsonEncode({
        'kind': 'cleanup',
        'pipeline': [
          {'kind': 'trim_trailing_spaces'},
          {'kind': 'remove_ad_lines'},
        ],
      });
      var plan = (await tester.runAsync(
        () => session.preview(template, [id], append: false),
      ))!;
      await tester.runAsync(() async {
        expect(plan.ready, isTrue);
        final lines = <int>[];
        for (final offset in [0, 40, 80]) {
          final page = await session.differences(plan, id, offset: offset);
          expect(page.total, 85);
          expect(page.candidateTotal, 45);
          expect(page.actions.length, offset == 80 ? 5 : 40);
          expect(
            page.candidates.length,
            offset == 0
                ? 40
                : offset == 40
                ? 5
                : 0,
          );
          lines.addAll(page.actions.map((v) => v.line));
        }
        expect(lines, List.generate(85, (i) => i + 2));
        expect(session.isCurrent(plan), isTrue);
        expect(backend.cleanup.drafts.containsKey(id), isFalse);
        final pending = session.differences(plan, id, offset: 40);
        session.cancel();
        await expectLater(pending, throwsFormatException);
        await expectLater(session.differences(plan, id), throwsFormatException);
        plan = await session.preview(template, [id], append: false);
      });
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(),
            home: Scaffold(
              body: CleanupBatchDifferenceDialog(
                session: session,
                plan: plan,
                bookId: id,
                title: '分页清理',
              ),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        await tester.pump();
        for (
          var i = 0;
          i < 300 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(find.byType(LinearProgressIndicator), findsNothing);
      }

      await settle();
      expect(find.text('1–40 / 85 条'), findsOneWidget);
      await tester.tap(find.text('下一页'));
      await settle();
      expect(find.text('41–80 / 85 条'), findsOneWidget);
      await tester.tap(find.text('下一页'));
      await settle();
      expect(find.text('81–85 / 85 条'), findsOneWidget);
      await tester.tap(find.text('显示空白'));
      await tester.pump();
      expect(find.text('正文81··'), findsOneWidget);
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/differences-page3.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('提示候选'));
      await settle();
      expect(find.text('1–40 / 45 条'), findsOneWidget);
      expect(find.textContaining('未选择删除'), findsWidgets);
      await tester.tap(find.text('下一页'));
      await settle();
      expect(find.text('41–45 / 45 条'), findsOneWidget);
      await tester.tap(find.text('最终变更'));
      await settle();
      expect(find.text('1–40 / 85 条'), findsOneWidget);
      backend.change(() {
        backend.cleanup.drafts[id] =
            jsonDecode(template) as Map<String, dynamic>;
      });
      await tester.pump();
      expect(find.text('书稿或项目状态已改变，请返回重新预览。'), findsOneWidget);
      expect(find.text('1–40 / 85 条'), findsNothing);
      await tester.runAsync(() async {
        await expectLater(session.apply(plan), throwsFormatException);
        expect(await source.readAsString(), original);
      });
      expect(tester.takeException(), isNull);
    },
  );
}
