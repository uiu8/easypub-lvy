import 'dart:io';

import 'package:easypub_desktop/desk/checks/checks_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// V113：纯数字标题改为提示式。导入不再悄悄打开纯数字识别；检查页顶部汇总提示，
/// 一个按钮打开“数字章节”，核对后一次识别并统一为“第X章 标题”，之后提示消失。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('检查页提示纯数字标题，一键识别并统一为第X章', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v113-numeric-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final text = StringBuffer();
      for (var n = 1; n <= 12; n++) {
        text.writeln('${n.toString().padLeft(3, '0')}：第$n个故事');
        for (var p = 1; p <= 3; p++) {
          text.writeln('　　第$n个故事的第$p段正文。');
        }
      }
      final file = File('$root/数字标题.txt')..writeAsStringSync('$text');
      await library.importFiles([file.path]);
      id = state.currentId;
      // 一章都没识别出来时章节检查也要成功（以前“全书未识别标题”排第一会让检查失败）。
      final report = await library.openChecks(state.currentId).inspect();
      final chapterDomain = report.domains.firstWhere(
        (d) => d.id == 'chapters',
      );
      expect(chapterDomain.failed, isFalse);
      // 导入不再自动打开纯数字识别：一章都没有识别出来。
      final page = await library.openChapters(id).read(0);
      expect(page.nodes.where((n) => n.title.contains('故事')), isEmpty);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> settle() async {
      for (var i = 0; i < 150; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 20));
        if (i > 10 &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          return;
        }
      }
    }

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: BookChecksPage(
            library: library,
            bookId: id,
            onRepair: (_) {},
            onChapter: (_) {},
            onCatalog: () {},
            onCleanup: () {},
          ),
        ),
      ),
    );
    await settle();
    final hint = find.byKey(const ValueKey('check-numeric-hint'));
    expect(hint, findsOneWidget);
    expect(
      find.descendant(of: hint, matching: find.textContaining('发现 12 个纯数字标题')),
      findsOneWidget,
    );

    await t.tap(find.byKey(const ValueKey('check-numeric-apply')));
    await settle();
    expect(
      t.widget<Text>(find.byKey(const ValueKey('numeric-summary'))).data,
      startsWith('找到 12 个数字标题'),
    );
    await t.tap(find.byKey(const ValueKey('numeric-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('numeric-apply')));
    await settle();
    expect(find.byKey(const ValueKey('numeric-summary')), findsNothing);
    final titles = await t.runAsync(() async {
      final page = await library.openChapters(id).read(0);
      return page.nodes.map((n) => n.title).toList();
    });
    expect(titles, containsAll(['第一章 第1个故事', '第十二章 第12个故事']));
    // 识别后重新检查，提示消失。
    expect(hint, findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
