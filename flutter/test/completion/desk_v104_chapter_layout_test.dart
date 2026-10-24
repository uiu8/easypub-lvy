import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/desk/chapters/chapter_view_state.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

const _sample =
    '第一章 开始\n正文一。\n【叮！检测到任务】\n正文二。\n【山门试炼】\n【任务：守住山门三日】\n【奖励：灵石一百】\n'
    '床前明月光，疑是地上霜。\n举头望明月，低头思故乡。\n正文三。\n正文四。\n第二章 下山\n天亮了。\n';

/// V104：章节页排版视图（LAY-148–151）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('排版视图：按识别结果显示、悬停出标签、点标签取消识别、拖选几行标为诗词、切回原文', (t) async {
    t.view.physicalSize = const Size(1440, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final root = (await Directory(
        '../artifacts',
      ).createTemp('v104-layout-view-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final source = File('$root/系统流.txt')..writeAsStringSync(_sample);
      expect((await library.importFiles([source.path])).single.succeeded, true);
      id = state.currentId;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> until(bool Function() ready, String what) async {
      for (var i = 0; i < 500; i++) {
        await t.pump(const Duration(milliseconds: 20));
        if (ready()) return;
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      fail('未就绪：$what');
    }

    List annotations() =>
        (state.production.settings(id)['block_annotations'] as List?) ??
        const [];
    String counts() =>
        t
            .widget<Text>(find.byKey(const ValueKey('chapter-layout-counts')))
            .data ??
        '';
    Finder bars() => find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey &&
          (w.key as ValueKey).value is Record &&
          '${(w.key as ValueKey).value}'.startsWith('(layout-bar'),
    );

    final view = ChapterViewState();
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChapterWorkspace(library: library, bookId: id, viewState: view),
        ),
      ),
    );
    final mode = find.byKey(const ValueKey('chapter-layout-mode'));
    await until(() => mode.evaluate().isNotEmpty, '原文与排版切换');
    // 原文：没有色条，可以选字复制。
    expect(bars(), findsNothing);
    expect(find.byType(SelectionArea), findsWidgets);

    await t.tap(find.descendant(of: mode, matching: find.text('排版')));
    await until(() => counts().startsWith('本章 系统提示 2 · 诗词 1'), '本章识别数量');
    expect(view.layoutView, true);
    // 2 行单行提示 + 面板 3 行 + 诗词 2 行，各有色条；排版视图里不再选字。
    expect(bars(), findsNWidgets(6));
    expect(find.byType(SelectionArea), findsNothing);
    // 标题面板：首行作标题、去括号，键名单独加粗。
    expect(find.text('山门试炼'), findsOneWidget);
    expect(find.textContaining('守住山门三日'), findsOneWidget);
    expect(find.text('【叮！检测到任务】'), findsOneWidget, reason: '提示条保留括号');

    // 悬停在单行提示上才出标签。
    expect(find.text('系统提示 · 单行 · 自动'), findsNothing);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: t.getCenter(find.text('【叮！检测到任务】')));
    addTearDown(mouse.removePointer);
    await t.pump();
    expect(find.text('系统提示 · 单行 · 自动'), findsOneWidget);

    // 点标签选中这一块，用“取消识别”标注，确认后写入；这一行改成手工色条与手工标签。
    await t.tap(find.text('系统提示 · 单行 · 自动'));
    await t.pump();
    expect(find.byKey(const ValueKey('block-mark-bar')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey(('block-mark-choose', 'none'))));
    await until(
      () => find
          .byKey(const ValueKey('block-mark-confirm'))
          .evaluate()
          .isNotEmpty,
      '确认步骤',
    );
    await t.tap(find.byKey(const ValueKey('block-mark-confirm')));
    await until(() => annotations().length == 1, '标注写入');
    expect(annotations().single['kind'], 'none');
    await until(() => counts().startsWith('本章 系统提示 1 · 诗词 1 · 手工标注 1'), '重新识别');

    // 拖选“正文三”“正文四”两行，标为诗词。
    final from = t.getCenter(find.text('正文三。'));
    final to = t.getCenter(find.text('正文四。'));
    final drag = await t.startGesture(from);
    await t.pump(const Duration(milliseconds: 30));
    for (var i = 1; i <= 8; i++) {
      await drag.moveTo(Offset.lerp(from, to, i / 8)!);
      await t.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await t.pump();
    expect(find.byKey(const ValueKey('block-mark-bar')), findsOneWidget);
    expect(find.textContaining('第 10–11 行'), findsWidgets);
    await t.tap(find.byKey(const ValueKey(('block-mark-choose', 'verse'))));
    await until(
      () => find
          .byKey(const ValueKey('block-mark-confirm'))
          .evaluate()
          .isNotEmpty,
      '确认步骤',
    );
    await t.tap(find.byKey(const ValueKey('block-mark-confirm')));
    await until(() => annotations().length == 2, '第二条标注写入');
    expect(annotations().map((a) => a['kind']), containsAll(['none', 'verse']));
    await until(() => counts().contains('手工标注 2'), '手工标注计数');

    // 切回原文：可以选字，色条消失。
    await t.tap(find.descendant(of: mode, matching: find.text('原文')));
    await until(() => find.byType(SelectionArea).evaluate().isNotEmpty, '回到原文');
    expect(bars(), findsNothing);
    expect(view.layoutView, false);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
