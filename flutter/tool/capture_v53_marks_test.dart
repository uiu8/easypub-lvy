import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/block_annotation_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/fonts.dart';

/// V53 界面截图：已有书信标注（括号与标签）与新框选的工具条。
/// `tools/test_flutter.ps1 -TestPaths tool/capture_v53_marks_test.dart`，输出 artifacts/v53-preview/。
void main() {
  testWidgets('截图：章节页手工标注', (t) async {
    final capture = GlobalKey();
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      await loadDeskFonts();
      for (final font in {
        'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(font.key)..addFont(
              File(font.value).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
      }
      final out = Directory('../artifacts/v53-preview')
        ..createSync(recursive: true);
      final root = (await out.createTemp('data-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/来信.txt')
        ..writeAsStringSync(
          '第一章 来信\n'
          '　　信是傍晚送到的，他拆开一看，是阿青的字迹：\n'
          '　　周叔：见字如面。\n'
          '　　港口的雾一年比一年大，您出海时千万当心……\n'
          '　　阿青 十月十五日\n'
          '　　他把信折好，放进怀里。\n'
          '【叮！任务开启】\n'
          '　　你已获得：旧船票一张\n'
          '　　他愣了一下，抬头看天。\n'
          '第二章 下山\n天亮了。\n',
        );
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
      // 先写入一条书信标注（第 2–4 行），截图时显示括号与标签。
      final blocks = library.openBlockAnnotations(id);
      final snapshot = await blocks.list();
      final node = (await library.openChapters(id).read(0)).nodes.first;
      final range = await blocks.resolveLines(
        snapshot,
        entryId: node.id,
        firstLine: 2,
        lastLine: 4,
      );
      await blocks.confirm(
        await blocks.previewAdd(
          snapshot,
          start: range.start,
          end: range.end,
          kind: BlockAnnotationKind.letter,
        ),
      );
      blocks.dispose();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    t.view.physicalSize = const Size(1100, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: ChapterWorkspace(library: library, bookId: id),
          ),
        ),
      ),
    );
    Finder number(int line) => find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey &&
          key.value is (String, String, int) &&
          (key.value as (String, String, int)).$1 == 'line-number' &&
          (key.value as (String, String, int)).$3 == line;
    });
    for (var i = 0; i < 300 && find.text('书信 · 手工').evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    await t.tap(number(6));
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.tap(number(7));
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('../artifacts/v53-preview/chapter-marks.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    expect(t.takeException(), isNull);
  });
}
