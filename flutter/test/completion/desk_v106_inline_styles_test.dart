import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/desk/chapters/chapter_view_state.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/chapters/inline_style_marks.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

const _sample = '第一章 开始\n甲乙丙丁戊。\n己庚辛壬癸。\n子丑寅卯辰。\n第二章 结束\n保留。\n';

/// V106：章节页文字样式界面（LAY-152）：跨行选择一次写入、一次撤销；格式提示；改与删。
void main() {
  test('样式分段：显示文字去掉首尾空白时区间平移，几种样式叠加', () {
    final span = inlineStyledSpan('　甲乙丙', '甲乙丙', [
      (from: 1, to: 3, style: 'bold'),
      (from: 2, to: 3, style: 'wavy'),
    ]) as TextSpan;
    final parts = span.children!.cast<TextSpan>();
    expect(parts.map((p) => p.text), ['甲', '乙', '丙']);
    expect(parts[0].style!.fontWeight, FontWeight.w700);
    expect(parts[1].style!.fontWeight, FontWeight.w700);
    expect(parts[1].style!.decorationStyle, TextDecorationStyle.wavy);
    expect(parts[2].style!.fontWeight, isNull);
    // 显示文字在原文里找不到（例如去掉了括号）时不画样式。
    expect(
      (inlineStyledSpan('【甲】', '乙', [
        (from: 0, to: 1, style: 'bold'),
      ]) as TextSpan).text,
      '乙',
    );
  });

  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('跨三行加两种样式记为一步；单行波浪线有格式提示；已有样式可改可删', (t) async {
    t.view.physicalSize = const Size(1440, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    late File source;
    late List<int> original;
    await t.runAsync(() async {
      final root = (await Directory(
        '../artifacts',
      ).createTemp('v106-inline-styles-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      source = File('$root/样式.txt')..writeAsStringSync(_sample);
      original = source.readAsBytesSync();
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

    // 对话框里的光标一直闪，pumpAndSettle 等不到静止；按固定帧推进。
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    List styles() =>
        (state.production.settings(id)['inline_styles'] as List?) ?? const [];
    String counts() =>
        t
            .widget<Text>(find.byKey(const ValueKey('chapter-layout-counts')))
            .data ??
        '';
    bool shown(Key key) => find.byKey(key).evaluate().isNotEmpty;
    void select(int from, int to) {
      final field = t.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('inline-style-text')),
          matching: find.byType(EditableText),
        ),
      );
      field.controller.selection = TextSelection(
        baseOffset: from,
        extentOffset: to,
      );
    }

    Future<void> previewAndConfirm() async {
      await t.tap(find.byKey(const ValueKey('inline-style-preview')));
      await until(
        () => shown(const ValueKey('inline-style-preview-body')),
        '预览',
      );
      await t.tap(find.byKey(const ValueKey('inline-style-confirm')));
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
    final mode = find.byKey(const ValueKey('chapter-layout-mode'));
    await until(() => mode.evaluate().isNotEmpty, '原文与排版切换');
    await t.tap(find.descendant(of: mode, matching: find.text('排版')));
    await until(() => counts().startsWith('本章 系统提示'), '排版视图');

    // 拖选三行，工具条上有“文字样式…”。
    final from = t.getCenter(body('甲乙丙丁戊。'));
    final to = t.getCenter(body('子丑寅卯辰。'));
    final drag = await t.startGesture(from);
    await t.pump(const Duration(milliseconds: 30));
    for (var i = 1; i <= 8; i++) {
      await drag.moveTo(Offset.lerp(from, to, i / 8)!);
      await t.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await t.pump();
    await t.tap(find.byKey(const ValueKey('inline-style-open')));
    await settle();
    expect(find.text('文字样式 · 第 2–4 行'), findsOneWidget);

    // 从第一行的“丙”选到第三行的“丑”；换行不算，拆成三段。
    select(2, 16);
    await t.pump();
    expect(
      t.widget<Text>(find.byKey(const ValueKey('inline-style-selection'))).data,
      contains('已选中 3 行'),
    );
    await t.tap(find.byKey(const ValueKey(('inline-style-choose', 'bold'))));
    await t.tap(
      find.byKey(const ValueKey(('inline-style-choose', 'underline'))),
    );
    await t.pump();
    expect(find.byKey(const ValueKey('inline-style-effect')), findsOneWidget);
    await previewAndConfirm();
    await until(() => styles().length == 6, '跨行样式写入');
    await until(
      () => find.byType(InlineStyleDialog).evaluate().isEmpty,
      '确认后关闭对话框',
    );
    await until(() => counts().contains('文字样式 6'), '页眉计数');
    expect(source.readAsBytesSync(), original, reason: '原稿不改');

    // 一次撤销撤回整批。
    await t.runAsync(() async {
      final session = library.openInlineStyles(id);
      await session.confirm(await session.previewUndo());
      session.dispose();
    });
    await until(() => styles().isEmpty, '撤销整批');
    await until(() => !counts().contains('文字样式'), '页眉计数清零');

    // 单行：点一行打开，选波浪线出 KFX 提示；楷体与仿宋只能选一种。
    await t.tap(body('己庚辛壬癸。'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('inline-style-open')));
    await settle();
    expect(find.text('文字样式 · 第 3 行'), findsOneWidget);
    select(0, 2);
    await t.tap(find.byKey(const ValueKey(('inline-style-choose', 'wavy'))));
    await t.pump();
    expect(
      find.byKey(
        const ValueKey(('inline-style-format-note', 'kfx_underline_fallback')),
      ),
      findsOneWidget,
    );
    await t.tap(find.byKey(const ValueKey(('inline-style-choose', 'kai'))));
    await t.tap(
      find.byKey(const ValueKey(('inline-style-choose', 'fang_song'))),
    );
    await t.pump();
    bool chosen(String s) => t
        .widget<FilterChip>(find.byKey(ValueKey(('inline-style-choose', s))))
        .selected;
    expect(chosen('kai'), false);
    expect(chosen('fang_song'), true);
    await t.tap(
      find.byKey(const ValueKey(('inline-style-choose', 'fang_song'))),
    );
    await previewAndConfirm();
    await until(() => styles().length == 1, '单行样式写入');
    await until(
      () => find.byType(InlineStyleDialog).evaluate().isEmpty,
      '确认后关闭对话框',
    );
    expect(styles().single['style'], 'wavy');

    // 再打开这一行：已有样式列在下面，改为下划线后删除，都先预览。
    await t.tap(body('己庚辛壬癸。'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('inline-style-open')));
    await settle();
    final styleId = styles().single['id'] as String;
    await t.tap(find.byKey(ValueKey(('inline-style-change', styleId))));
    await settle();
    await t.tap(
      find.byKey(ValueKey(('inline-style-change-to', styleId, 'underline'))),
    );
    await until(
      () => shown(const ValueKey('inline-style-preview-body')),
      '修改预览',
    );
    expect(find.text('原为波浪线'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('inline-style-confirm')));
    await until(() => styles().single['style'] == 'underline', '修改写入');
    await until(
      () => shown(ValueKey(('inline-style-delete', styleId))),
      '回到对话框',
    );
    await t.tap(find.byKey(ValueKey(('inline-style-delete', styleId))));
    await until(
      () => shown(const ValueKey('inline-style-preview-body')),
      '删除预览',
    );
    await t.tap(find.byKey(const ValueKey('inline-style-confirm')));
    await until(() => styles().isEmpty, '删除写入');
    await until(
      () => !shown(const ValueKey('inline-style-preview-body')),
      '删除后回到对话框',
    );
    expect(
      find.byKey(ValueKey(('inline-style-existing', styleId))),
      findsNothing,
    );
    await t.tap(
      find.descendant(
        of: find.byType(InlineStyleDialog),
        matching: find.text('取消'),
      ),
    );
    await settle();
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}

/// 正文里的一行：排版视图按书页画，文字在语义标签里（侧栏摘录里也可能有同样的文字）。
Finder body(String text) => find.descendant(
  of: find.byType(CustomScrollView),
  matching: find.bySemanticsLabel(RegExp(RegExp.escape(text))),
);
