import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/cleanup/inline_diff.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/shell/save_badge.dart';

class _NoPicker extends Fake implements BookFilePicker {}

/// V15c：按用户取舍处理巡检问题（第 2、4、5、9、10、14、15、16、19、20 条）
/// 与书库详情栏对齐。真实应用、真实 Rust。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('行内差异只标出改动的一段；空白改动加标记，未改动的缩进不加（CLEAN-100）', () {
    const base = TextStyle(), changed = TextStyle(color: Color(0xFFFF0000));
    List<(String, bool)> parts(TextSpan span) => [
      for (final child in span.children!.cast<TextSpan>())
        (child.text!, child.style == changed),
    ];
    // 行尾两个空格被删去：只有这两个空格被标出，并显示为空白标记。
    final before = inlineDiffSpan(
      '　　港口起雾。  ',
      '　　港口起雾。',
      base: base,
      changed: changed,
    );
    expect(parts(before), [('　　港口起雾。', false), ('··', true)]);
    final after = inlineDiffSpan(
      '　　港口起雾。',
      '　　港口起雾。  ',
      base: base,
      changed: changed,
    );
    expect(parts(after), [('　　港口起雾。', false)]);
    // 中间改字：共同开头与结尾不着色。
    final word = inlineDiffSpan(
      '第一章 雾起',
      '第1章 雾起',
      base: base,
      changed: changed,
    );
    expect(parts(word), [('第', false), ('一', true), ('章 雾起', false)]);
    // 打开“显示空白标记”时全部空白都有标记，全角空格为 □。
    final marked = inlineDiffSpan(
      '　a b',
      '　a b',
      base: base,
      changed: changed,
      marks: true,
    );
    expect(parts(marked), [('□a·b', false)]);
    // 不拆开代理对。
    final ends = commonEnds('a😀b', 'a😁b');
    expect(ends.prefix, 1);
    expect(ends.suffix, 1);
  });

  test('作者为空时，成品文件名与生成封面不再写入占位文字“待补充作者”（LIB-107）', () async {
    final root = (await Directory('../artifacts').createTemp('v15c-author-'))
        .absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final session = LegacyConversionSession(state);
    try {
      await library.load();
      await library.savePatch({
        'check_after_import': false,
        'output_naming': 'title_author',
      });
      final file = File('${root.path}/无名书.txt')
        ..writeAsStringSync('第一章 开始\n　　正文。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final sample = state.shelf.books.where((b) => !b.isDemo).single;
      expect(state.authorOf(sample), isEmpty);
      expect(library.books.value.single.author, isEmpty);
      final plan = await session.preview(
        ConversionRequest(
          books: [library.books.value.single.id],
          directory: '${root.path}/output',
          format: 'EPUB',
          engine: Platform.environment['EASYPUB_TEST_KINDLING']!,
          generateCover: true,
          runChecks: false,
        ),
      );
      final outputs = await session.commit(plan, acknowledgeWarnings: true);
      expect(outputs.single.phase, 'complete');
      final name = outputs.single.path.replaceAll('\\', '/').split('/').last;
      expect(name, '无名书.epub');
      expect(name, isNot(contains('待补充作者')));
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  test('机型短名与草稿保存的说明（LAY-102、G-066）', () {
    expect(kindleShortName('KPW6 / Paperwhite 第 12 代（7 英寸）'), 'KPW6');
    expect(kindleShortName('Kindle Scribe（10.2 英寸）'), 'Scribe');
    expect(kindleShortName('Kindle 基础款第 10 代（6 英寸）'), '基础款第 10 代');
    expect(DeskSaveBadge.label(DeskSaveState.saved), '草稿已自动保存');
  });

  testWidgets(
    '书库详情栏与书架对齐、只算章节问题、作者为空、批量条不推动书架；排版与清理（LIB-105–108、LAY-102/103、CLEAN-101/102）',
    (t) async {
      const channel = MethodChannel('window_manager');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      t.view.physicalSize = const Size(1500, 950);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late String foggy;
      await t.runAsync(() async {
        final root = (await Directory('../artifacts').createTemp('v15c-'))
            .absolute
            .path;
        state = PrototypeState(settingsDirectory: '$root/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        final text = StringBuffer();
        for (var i = 1; i <= 8; i++) {
          if (i == 5) continue; // 缺第五章：章节问题
          text.writeln('第$i章 雾起$i');
          text.writeln('　　港口的雾又起来了。  ');
          text.writeln('');
          text.writeln('');
        }
        for (final (name, body) in [
          ('雾港来信', text.toString()),
          ('长街', '第1章 长街\n　　正文。\n第2章 灯\n　　正文。\n'),
        ]) {
          final file = File('$root/$name.txt')..writeAsStringSync(body);
          expect(
            (await library.importFiles([file.path])).single.succeeded,
            true,
          );
        }
        foggy = library.books.value.firstWhere((b) => b.title == '雾港来信').id;
        for (final b in library.books.value) {
          final checks = library.openChecks(b.id);
          try {
            await checks.inspect();
          } finally {
            checks.dispose();
          }
        }
        library.selectBook(foggy);
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      Future<void> settle() async {
        for (var i = 0; i < 60; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump(const Duration(milliseconds: 30));
        }
      }

      await t.pumpWidget(RewriteApp(library: library, picker: _NoPicker()));
      await settle();
      final book = library.books.value.firstWhere((b) => b.id == foggy);
      // 作者为空：不再是占位文字“待补充作者”（LIB-107）。
      expect(book.author, isEmpty);
      expect(find.textContaining('待补充作者'), findsNothing);
      expect(find.text('未填作者'), findsWidgets);
      // 角标只算章节问题；清理建议与书籍信息在详情中分行（LIB-106）。
      final pending = book.pending!;
      expect(pending.chapters, greaterThan(0));
      expect(pending.total, greaterThan(pending.chapters));
      expect(
        find.descendant(
          of: find.byKey(ValueKey('library-badge-$foggy')),
          matching: find.text('${pending.chapters}'),
        ),
        findsOneWidget,
      );
      expect(find.text('章节问题 ${pending.chapters} 项'), findsOneWidget);
      expect(find.text('清理建议'), findsOneWidget);
      // 宽窗口：有详情栏，不再显示“当前书详情”（LIB-108）；数量在标题里。
      expect(
        find.byKey(const ValueKey('library-detail-column')),
        findsOneWidget,
      );
      expect(find.text('当前书详情'), findsNothing);
      expect(find.text('2 本'), findsOneWidget);
      // 两栏封面顶端对齐（LIB-105）。
      Rect coverOf(Finder scope) => t.getRect(
        find
            .descendant(
              of: scope,
              matching: find.byKey(const ValueKey('generated-cover')),
            )
            .first,
      );
      final shelfCover = coverOf(find.byKey(ValueKey('library-row-$foggy')));
      final panelCover = coverOf(
        find.byKey(const ValueKey('library-detail-column')),
      );
      expect((shelfCover.top - panelCover.top).abs(), lessThan(1));
      final detail = t.getRect(
        find.byKey(const ValueKey('library-detail-column')),
      );
      final search = t.getRect(find.byType(TextField).first);
      expect(detail.top, lessThan(search.top));
      // 勾选一本书：批量操作条浮在书架底部，书架不移动。
      await t.tap(find.byTooltip('全选筛选结果'));
      await t.pump();
      expect(
        find.byKey(const ValueKey('library-selection-bar')),
        findsOneWidget,
      );
      expect(
        coverOf(find.byKey(ValueKey('library-row-$foggy'))).top,
        shelfCover.top,
      );
      expect(
        t.getRect(find.byKey(const ValueKey('library-selection-bar'))).top,
        greaterThan(shelfCover.bottom),
      );
      await t.tap(find.byTooltip('取消筛选结果勾选'));
      await t.pump();
      expect(find.byKey(const ValueKey('library-selection-bar')), findsNothing);

      // 排版：1100 宽时机型写短名、预览设置一行、标题不省略（LAY-102、LAY-103）。
      final router = GoRouter.of(t.element(find.byType(Navigator).first));
      t.view.physicalSize = const Size(1100, 720);
      router.go('/books/${Uri.encodeComponent(foggy)}/layout');
      await settle();
      expect(find.text('KPW6'), findsOneWidget);
      final device = t.getRect(
        find.byKey(const ValueKey('layout-preview-device')),
      );
      final reader = t.getRect(
        find.byKey(const ValueKey('layout-reader-settings')),
      );
      expect((reader.center.dy - device.center.dy).abs(), lessThan(4));
      final indent = find.text('段首全角空格');
      expect(t.getSize(indent).height, lessThan(24));
      expect(t.takeException(), isNull);

      // 清理：只标出行尾空白；分隔线可拖动；编辑 / 删除规则带图标（CLEAN-100–102）。
      t.view.physicalSize = const Size(1500, 950);
      router.go('/books/${Uri.encodeComponent(foggy)}/cleanup');
      await settle();
      expect(find.byIcon(Icons.edit_outlined), findsWidgets);
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
      final row = t.widget<Text>(
        find.byKey(const ValueKey('cleanup-before-0')),
      );
      final spans = (row.textSpan! as TextSpan).children!.cast<TextSpan>();
      expect(spans.last.text, '··');
      expect(spans.first.text, contains('港口的雾又起来了。'));
      final handle = find.byKey(const ValueKey('cleanup-split-handle'));
      final list = find.byKey(const ValueKey('cleanup-before-0'));
      final top = t.getRect(handle).top;
      final drag = await t.startGesture(
        t.getCenter(handle),
        kind: PointerDeviceKind.mouse,
      );
      for (var i = 0; i < 8; i++) {
        await drag.moveBy(const Offset(0, -10));
        await t.pump();
      }
      await drag.up();
      await t.pump();
      expect(t.getRect(handle).top, lessThan(top - 40));
      expect(list, findsOneWidget);
      expect(t.takeException(), isNull);

      // 概览：只有底部的转换入口，项目文件状态写在“项目与来源”（LIB-109、LIB-110）。
      router.go('/books/${Uri.encodeComponent(foggy)}/overview');
      await settle();
      expect(find.text('转换本书'), findsNothing);
      expect(
        find.byKey(const ValueKey('overview-project-state')),
        findsOneWidget,
      );
      expect(find.text('尚未另存为项目文件'), findsOneWidget);
      expect(find.text('项目有未保存更改'), findsNothing);
      expect(find.text('草稿已自动保存'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await settle();
    },
  );
}
