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
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'real chapter workspace keeps late-node body and undo identity with continuous navigation',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late String id, targetId;
      late File file;
      late String original;
      await tester.runAsync(() async {
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
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        final dir = (await Directory(
          '../artifacts',
        ).createTemp('continuous-chapters-')).absolute;
        state = PrototypeState(settingsDirectory: '${dir.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        original = List.generate(
          80,
          (i) =>
              '${i == 0
                  ? '第一卷 初行\n\n'
                  : i == 40
                  ? '第二卷 归途\n\n'
                  : ''}第${i + 1}章 标题${i + 1}\n\n这是第${i + 1}章独立正文。\n\n',
        ).join();
        file = File('${dir.path}/长篇.txt')..writeAsStringSync(original);
        expect((await library.importFiles([file.path])).single.succeeded, true);
        id = state.currentId;
        final chapters = library.openChapters(id);
        final page = await chapters.read(60);
        targetId = page.nodes.firstWhere((n) => n.title == '第65章 标题65').id;
        expect((await chapters.read(0)).nodes.first.role, 'volume');
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            theme: deskTheme(),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: ChapterWorkspace(
                  library: library,
                  bookId: id,
                  initialNodeId: targetId,
                  initialOffset: 60,
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 180; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (i > 4 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            return;
          }
        }
        fail('chapter workspace remained busy');
      }

      await settle();
      expect(find.byTooltip('下一页章节'), findsNothing);
      expect(find.byKey(ValueKey('tree-node-$targetId')), findsOneWidget);
      expect(
        find.textContaining('这是第65章独立正文', findRichText: true),
        findsWidgets,
      );
      await tester.tap(find.byKey(const ValueKey('chapter-toc')));
      await settle();
      await tester.runAsync(() async {
        final p = await library.openChapters(id).read(60);
        expect(p.nodes.firstWhere((n) => n.id == targetId).inToc, false);
        expect(
          p.nodes.where((n) => n.id != targetId).every((n) => n.inToc),
          true,
        );
      });
      expect(
        find.textContaining('这是第65章独立正文', findRichText: true),
        findsWidgets,
      );
      await tester.tap(find.byKey(const ValueKey('chapter-undo')));
      await settle();
      await tester.runAsync(() async {
        final p = await library.openChapters(id).read(60);
        expect(p.nodes.firstWhere((n) => n.id == targetId).inToc, true);
      });
      expect(find.byKey(ValueKey('tree-node-$targetId')), findsOneWidget);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final width in [1050.0, 820.0, 600.0]) {
        tester.view.physicalSize = Size(width, 960);
        await tester.pumpAndSettle();
        final tabs = find.byKey(const ValueKey('chapter-content-tabs'));
        await tester.tap(find.descendant(of: tabs, matching: find.text('问题')));
        await settle();
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.descendant(of: tabs, matching: find.text('变更记录')),
        );
        await tester.pumpAndSettle();
        expect(find.text('修改章节'), findsWidgets);
        expect(find.byTooltip('选择记录书籍'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.descendant(of: tabs, matching: find.text('正文')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('这是第65章独立正文', findRichText: true),
          findsWidgets,
        );
        if (width < 1040) {
          await tester.tap(find.byTooltip('章节设置'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('chapter-toc')), findsOneWidget);
          await tester.tap(find.byTooltip('关闭章节设置'));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        if (width == 1050 || width == 600) {
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final data = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            await File('../artifacts/chapter-workspace-${width.toInt()}.png')
                .writeAsBytes(data.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      await tester.tap(find.byTooltip('章节设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chapter-toc')));
      await settle();
      await tester.tap(find.byTooltip('关闭章节设置'));
      await tester.pumpAndSettle();
      final tabs = find.byKey(const ValueKey('chapter-content-tabs'));
      await tester.tap(find.descendant(of: tabs, matching: find.text('变更记录')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改章节').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('撤销此次修改'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销此次修改'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认撤销'));
      await settle();
      await tester.tap(find.descendant(of: tabs, matching: find.text('正文')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('这是第65章独立正文', findRichText: true),
        findsWidgets,
      );
      await tester.runAsync(() async {
        final p = await library.openChapters(id).read(60);
        expect(p.nodes.firstWhere((n) => n.id == targetId).inToc, true);
      });
      expect(file.readAsStringSync(), original);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
