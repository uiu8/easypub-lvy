import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/desk/chapters/chapter_view_state.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/chapters/inline_style_marks.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

String _sample() {
  final b = StringBuffer('第一章 入门\n');
  for (var i = 1; i <= 60; i++) {
    b.writeln(switch (i) {
      3 => '【叮！检测到宿主】',
      8 => '【新手任务】',
      9 => '【任务：在三日内拜入青云门】',
      10 => '【奖励：灵石一百、悟性丹一枚】',
      5 => '他把那封信看了又看，终于放下。',
      15 => '床前明月光，疑是地上霜。',
      16 => '举头望明月，低头思故乡。',
      52 => '【叮！获得称号：初入山门】',
      _ => '这是正文第 $i 段，山风吹过，竹影摇动。',
    });
  }
  b.writeln('第二章 下山');
  b.writeln('天亮了。');
  b.writeln('【叮！签到成功】');
  b.writeln('第三章 归来');
  b.writeln('一路无话。');
  return b.toString();
}

/// V120：章节页排版视图的“样式片段”侧栏（LAY-166）：逐处列出、筛选、点一处或上下一处跳过去、全书按章汇总。
void main() {
  testWidgets('样式片段侧栏：列出本章每一处套了样式的文字，点一处跳到该行，全书按章列出', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final shots = Platform.environment['EASYPUB_SHOT_DIR'];
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      if (shots != null) {
        for (final font in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'Desk Sans': 'C:/Windows/Fonts/msyh.ttc',
          'Desk Serif': 'C:/Windows/Fonts/msyh.ttc',
          'Desk Mono': 'C:/Windows/Fonts/consola.ttf',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(font.key)..addFont(
                File(font.value)
                    .readAsBytes()
                    .then((b) => b.buffer.asByteData()),
              ))
              .load();
        }
      }
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = (await Directory(
        '../artifacts',
      ).createTemp('v120-style-segments-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final source = File('$root/样式片段.txt')..writeAsStringSync(_sample());
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

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    final capture = GlobalKey();
    Future<void> shot(String name) async {
      if (shots == null) return;
      final boundary =
          capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await t.runAsync(() async {
        final img = await boundary.toImage();
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        img.dispose();
      });
    }

    String counts() =>
        t
            .widget<Text>(find.byKey(const ValueKey('chapter-layout-counts')))
            .data ??
        '';
    Finder segment(String group, int line) =>
        find.byKey(ValueKey(('style-segment', group, line)));
    final panel = find.byKey(const ValueKey('style-segments'));

    await t.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: deskTheme(),
          home: Scaffold(
            body: ChapterWorkspace(
              library: library,
              bookId: id,
              viewState: ChapterViewState(),
            ),
          ),
        ),
      ),
    );
    final mode = find.byKey(const ValueKey('chapter-layout-mode'));
    await until(() => mode.evaluate().isNotEmpty, '原文与排版切换');
    // 原文视图没有侧栏，右侧是章节设置。
    expect(panel, findsNothing);
    expect(find.text('章节设置'), findsOneWidget);
    await t.tap(find.descendant(of: mode, matching: find.text('排版')));
    await until(() => counts().startsWith('本章 系统提示'), '排版视图');
    expect(panel, findsOneWidget);
    // 排版视图不显示章节设置，空间让给样式片段。
    expect(find.text('章节设置'), findsNothing);
    expect(find.byTooltip('章节设置'), findsNothing);

    // 加一处文字样式：第 5 行“那封信”加粗。
    // 正文里的那一行（侧栏摘录里也有同样的文字）。
    await t.tap(body('他把那封信看了又看，终于放下。'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('inline-style-open')));
    await settle();
    t
        .widget<EditableText>(
          find.descendant(
            of: find.byKey(const ValueKey('inline-style-text')),
            matching: find.byType(EditableText),
          ),
        )
        .controller
        .selection = const TextSelection(
      baseOffset: 2,
      extentOffset: 5,
    );
    await t.pump();
    await t.tap(find.byKey(const ValueKey(('inline-style-choose', 'bold'))));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('inline-style-preview')));
    await until(
      () => find
          .byKey(const ValueKey('inline-style-preview-body'))
          .evaluate()
          .isNotEmpty,
      '预览',
    );
    await t.tap(find.byKey(const ValueKey('inline-style-confirm')));
    await until(
      () => find.byType(InlineStyleDialog).evaluate().isEmpty,
      '确认后关闭对话框',
    );
    await until(() => segment('style', 5).evaluate().isNotEmpty, '文字样式片段');

    // 单行提示、面板（三行合一处）、诗词（两行合一处）、文字样式、远处的单行提示，按行号排列。
    expect(segment('system', 3), findsOneWidget);
    expect(segment('system', 8), findsOneWidget);
    expect(segment('system', 9), findsNothing, reason: '面板三行算一处');
    expect(segment('verse', 15), findsOneWidget);
    expect(segment('system', 52), findsOneWidget);
    expect(
      find.descendant(of: segment('system', 8), matching: find.text('标题面板')),
      findsOneWidget,
      reason: '显示所用样式',
    );
    expect(
      find.descendant(of: segment('style', 5), matching: find.text('加粗')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: segment('style', 5), matching: find.text('那封信')),
      findsOneWidget,
    );
    // 远处还没读入的行另读摘录。
    await until(
      () => find
          .descendant(
            of: segment('system', 52),
            matching: find.text('【叮！获得称号：初入山门】'),
          )
          .evaluate()
          .isNotEmpty,
      '远处摘录',
    );
    await settle();
    await shot('chapter');

    // 点远处一处：正文跳到该行并标出。
    await t.tap(segment('system', 52));
    await until(() => body('正文第 50 段').evaluate().isNotEmpty, '跳到第 52 行');
    await settle();
    expect(panel, findsOneWidget, reason: '跳转后侧栏仍在');
    // 上一处：回到诗词那一处。
    await t.tap(find.byKey(const ValueKey('style-segments-previous')));
    await until(() => body('床前明月光').evaluate().isNotEmpty, '上一处');
    // 跳转后正文重读，远处片段的摘录另读。
    await until(
      () => find
          .descendant(
            of: segment('system', 52),
            matching: find.text('【叮！获得称号：初入山门】'),
          )
          .evaluate()
          .isNotEmpty,
      '跳转后的摘录',
    );
    await settle();
    await shot('jump');

    // 筛选：关掉“系统提示”，只剩诗词与文字样式。
    await t.tap(find.byKey(const ValueKey(('style-segments-group', 'system'))));
    await t.pump();
    expect(segment('system', 3), findsNothing);
    expect(segment('verse', 15), findsOneWidget);
    await t.tap(find.byKey(const ValueKey(('style-segments-group', 'system'))));
    await t.pump();

    // 全书：按章列出处数，第二章有一处系统提示；点它打开第二章。
    await t.tap(
      find.descendant(
        of: find.byKey(const ValueKey('style-segments-scope')),
        matching: find.text('全书'),
      ),
    );
    final second = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey &&
          '${(w.key as ValueKey).value}'.startsWith(
            '(style-segments-chapter',
          ) &&
          find
              .descendant(of: find.byWidget(w), matching: find.text('第二章 下山'))
              .evaluate()
              .isNotEmpty,
    );
    await until(() => second.evaluate().isNotEmpty, '全书列表');
    expect(
      find.descendant(of: panel, matching: find.text('第三章 归来')),
      findsNothing,
      reason: '没有样式的章不列',
    );
    await settle();
    await shot('book');
    await t.tap(second);
    await until(() => body('天亮了。').evaluate().isNotEmpty, '打开第二章');
    await until(() => segment('system', 2).evaluate().isNotEmpty, '第二章片段');
    expect(t.takeException(), isNull);
  });
}

/// 正文里的一行：排版视图按书页画，文字在语义标签里（侧栏摘录里也可能有同样的文字）。
Finder body(String text) => find.descendant(
  of: find.byType(CustomScrollView),
  matching: find.bySemanticsLabel(RegExp(RegExp.escape(text))),
);
