import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/manual_note_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:easypub_desktop/desk/rules/rules_page.dart';

Finder lineNumber(int line) => find.byWidgetPredicate((w) {
  final key = w.key;
  if (key is! ValueKey) return false;
  final value = key.value;
  return value is (String, String, int) &&
      value.$1 == 'line-number' &&
      value.$3 == line;
});

/// V62 / V63 界面截图：章节页手工注释、注释对话框、规则中心。输出 artifacts/v62-preview/。
void main() {
  testWidgets('截图：手工注释与规则中心', (t) async {
    final capture = GlobalKey();
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    const marked = '　　港口的雾（甲）从傍晚开始往岸上爬，先吞掉了灯塔的底座。';
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
      final out = Directory('../artifacts/v62-preview')
        ..createSync(recursive: true);
      final root = (await out.createTemp('data-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港来信.txt')
        ..writeAsStringSync(
          '第一章 雾港\n$marked\n作者注：这里的雾指海雾，春夏之交最常见。\n'
          '　　旧码头在晨光里显出轮廓。\n【叮！新手礼包已发放。】\n＊＊＊\n'
          '　　船夫收起缆绳，沿着木桥走向岸边。\n第二章 下山\n　　天亮了。\n',
        );
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
      final notes = library.openManualNotes(id);
      final tree = await library.openChapters(id).read(0);
      var snapshot = await notes.list();
      await notes.confirm(
        await notes.previewAdd(
          snapshot,
          ManualNoteDraft.pair(
            await notes.resolvePosition(
              snapshot,
              entryId: tree.nodes.first.id,
              line: 1,
              utf16Start: marked.indexOf('（甲）'),
              utf16End: marked.indexOf('（甲）') + 3,
            ),
            await notes.resolvePosition(
              snapshot,
              entryId: tree.nodes.first.id,
              line: 2,
              utf16Start: 0,
              utf16End: 0,
            ),
          ),
        ),
      );
      snapshot = await notes.list();
      await notes.confirm(
        await notes.previewAdd(
          snapshot,
          ManualNoteDraft.newText(
            await notes.resolvePosition(
              snapshot,
              entryId: tree.nodes.first.id,
              line: 3,
              utf16Start: 5,
              utf16End: 5,
            ),
            '旧码头：清末修建，后来废弃。',
          ),
        ),
      );
      notes.dispose();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    Future<void> settle([int n = 20]) async {
      for (var i = 0; i < n; i++) {
        await t.pump(const Duration(milliseconds: 40));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
    }

    Future<void> shoot(String name) => t.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('../artifacts/v62-preview/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });

    Widget app(Widget child) => RepaintBoundary(
      key: capture,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: deskTheme(),
        home: Scaffold(body: child),
      ),
    );

    await t.pumpWidget(app(ChapterWorkspace(library: library, bookId: id)));
    for (var i = 0; i < 300 && lineNumber(3).evaluate().isEmpty; i++) {
      await settle(1);
    }
    await settle();
    await t.tap(lineNumber(1));
    await settle(5);
    await shoot('chapter-notes');
    await t.tap(find.byKey(const ValueKey('note-open')));
    await settle(10);
    await shoot('note-dialog');
    await t.tap(find.text('取消').last);
    await settle(10);

    await t.pumpWidget(
      app(
        RulesPage(
          library: library,
          bookId: id,
          onOpenLocation: (_) {},
          onOpenSettings: (_) {},
        ),
      ),
    );
    for (var i = 0; i < 300; i++) {
      await settle(1);
      final tag = find.textContaining('已统计');
      if (tag.evaluate().isNotEmpty) break;
    }
    await settle(5);
    await shoot('rules');
    await t.drag(find.byType(Scrollable).last, const Offset(0, -900));
    await settle(5);
    final systemRow = find.textContaining('系统提示');
    if (systemRow.evaluate().isNotEmpty) {
      await t.tap(systemRow.first);
      await settle(5);
    }
    await shoot('rules-layout');
    expect(t.takeException(), isNull);
  });
}
