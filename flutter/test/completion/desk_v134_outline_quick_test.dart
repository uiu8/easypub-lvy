import 'dart:io';

import 'package:easypub_desktop/desk/chapters/chapter_view_state.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// V134：目录里选中的章节行直接显示“改为正文 / 合并 / 重命名”，不用打开菜单。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('选中章节行上的“改为正文”直接打开预览确认', (t) async {
    t.view.physicalSize = const Size(1440, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v134-quick-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final buffer = StringBuffer();
      for (var i = 1; i <= 4; i++) {
        buffer.writeln('第$i章 标题$i');
        for (var j = 0; j < 4; j++) {
          buffer.writeln('　　第$i章的正文第$j段。');
        }
      }
      final file = File('$root/快捷.txt')..writeAsStringSync('$buffer');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> until(bool Function() ready, String what) async {
      for (var i = 0; i < 400; i++) {
        await t.pump(const Duration(milliseconds: 20));
        if (ready()) return;
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      fail('未就绪：$what');
    }

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChapterWorkspace(
            library: library,
            bookId: id,
            viewState: ChapterViewState(),
          ),
        ),
      ),
    );
    final quick = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey &&
          '${(w.key as ValueKey).value}'.startsWith('chapter-quick-demote-'),
    );
    await until(() => quick.evaluate().isNotEmpty, '选中行的快捷按钮');
    // 只有选中的那一行显示（没有悬停时）。
    expect(quick, findsOneWidget);
    expect(find.byTooltip('合并章节'), findsWidgets);
    await t.tap(quick);
    await until(() => find.text('标题改为正文').evaluate().isNotEmpty, '改为正文的预览确认');
    expect(find.text('标题改为正文'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
