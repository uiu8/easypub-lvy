import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/history/change_history_page.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_removal_test.dart' show fixture, NoPicker;

void main() {
  testWidgets('legacy manual history can undo and redo from visible records', (
    t,
  ) async {
    t.view.physicalSize = const Size(1000, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
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
    });
    final (state, library, root) = (await t.runAsync(fixture))!;
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId, source = state.current.source!;
    await t.runAsync(() async {
      final manual = (jsonDecode(
        await api.editManualDraft(
          sourceId: source.sourceId,
          revision: source.revision,
          draftJson: '',
          commandJson: jsonEncode({
            'op': 'put',
            'action': {
              'kind': 'rename_title',
              'source_line': 1,
              'title': '第一章 旧版手工标题',
            },
          }),
        ),
      ) as Map).cast<String, dynamic>();
      state.change(() => state.manuscript.manualEditDrafts[id] = manual);
      expect(
        (await library.saveProject('$root/legacy.easypub.json')).succeeded,
        true,
      );
      expect(
        (await library.openProject('$root/legacy.easypub.json')).succeeded,
        true,
      );
    });
    final capture = GlobalKey();
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: RepaintBoundary(
          key: capture,
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: ChangeHistoryPage(
                library: library,
                history: library.openChangeHistory(),
                bookId: id,
                openEditor: (_, _) {},
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('修改人工编辑').first);
    await t.pump();
    await t.tap(find.text('撤销此次修改'));
    await t.pumpAndSettle();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(state.manuscript.manualEditDrafts[id]!['cursor'], 1);
    Future<void> waitCursor(int expected) async {
      for (var i = 0; i < 120; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
        if (state.manuscript.manualEditDrafts[id]!['cursor'] == expected) return;
      }
      fail('history cursor did not change');
    }

    await t.tap(find.text('撤销此次修改'));
    await t.pumpAndSettle();
    await t.tap(find.text('确认撤销'));
    await waitCursor(0);
    await t.pumpAndSettle();
    expect(find.text('已撤销'), findsWidgets);
    expect(find.text('修改标题'), findsOneWidget);
    expect(find.textContaining('1 / 原稿行号'), findsNWidgets(2));
    expect(find.textContaining('1 / 标题'), findsNWidgets(2));
    await t.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('../artifacts/completion-history85-ui.png')
          .writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
    await t.tap(find.text('重做此次修改'));
    await t.pumpAndSettle();
    await t.tap(find.text('确认重做'));
    await waitCursor(1);
    await t.pumpAndSettle();
    expect(
      (await t.runAsync(() => library.openChapters(id).read(0)))!
          .nodes
          .first
          .title,
      '第一章 旧版手工标题',
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
    final other = library.books.value.firstWhere((b) => b.id != id);
    library.selectBook(other.id);
    await t.pumpWidget(
      RewriteApp(
        library: library,
        picker: NoPicker(),
        initialLocation: '/history',
      ),
    );
    for (var i = 0; i < 100; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 20));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('history-book-choice')));
    await t.pumpAndSettle();
    final title = library.books.value.firstWhere((b) => b.id == id).title;
    await t.tap(find.widgetWithText(MenuItemButton, title));
    await t.pumpAndSettle();
    await t.tap(find.text('修改人工编辑').first);
    await t.pump();
    await t.tap(find.text('前往编辑'));
    for (var i = 0; i < 120; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump(const Duration(milliseconds: 20));
      if (find.byType(ChapterWorkspace).evaluate().isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    expect(
      t.widget<ChapterWorkspace>(find.byType(ChapterWorkspace)).bookId,
      id,
    );
    expect(library.selection.value.current, id);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
