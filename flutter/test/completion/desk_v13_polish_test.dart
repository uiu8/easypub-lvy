import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/candidate_dialog.dart';
import 'package:easypub_desktop/desk/cleanup/cleanup_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/dialogs.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/library/library_view_state.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';

class _NoPicker extends Fake implements BookFilePicker {}

/// V13：清理后重放章节修改、降级预览定位、排版预览放大、书库列表与详情。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  void size(WidgetTester t, Size s) {
    t.view.physicalSize = s;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Future<void> until(WidgetTester t, bool Function() ready) async {
    for (var i = 0; i < 600; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (ready()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    fail('界面未就绪');
  }

  Future<void> idle(WidgetTester t) => until(
    t,
    () =>
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty,
  );

  Future<(PrototypeState, LegacyLibraryAdapter)> open(
    WidgetTester t,
    String prefix,
    Map<String, String> books,
  ) async {
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp(prefix))
          .absolute;
      state = PrototypeState(settingsDirectory: '${root.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      for (final e in books.entries) {
        final file = File('${root.path}/${e.key}.txt')
          ..writeAsStringSync(e.value);
        expect((await library.importFiles([file.path])).single.succeeded, true);
      }
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    return (state, library);
  }

  Widget app(Widget child) => MaterialApp(
    theme: deskTheme(),
    home: Scaffold(body: child),
  );

  // 第一章第 3、4 行是连续空行；合并空行会删掉其中一行。
  const blanks = '第一章 开始\n甲文  \n\n\n乙文\n第二章 后续\n丙文\n';
  const pipeline = {
    'kind': 'cleanup',
    'pipeline': [
      {'kind': 'trim_trailing_spaces'},
      {'kind': 'collapse_blank_lines'},
    ],
  };

  /// 改名第一章；[exclude] 时再删除第一章的两行空行（第 3–4 行）。
  Future<void> edit(
    LegacyLibraryAdapter library,
    String id, {
    bool exclude = false,
  }) async {
    final chapters = library.openChapters(id);
    final page = await chapters.read(0);
    await chapters.rename(page, page.nodes.first.id, '第一章 改名');
    if (exclude) {
      final next = await chapters.read(0);
      await chapters.confirm(
        await chapters.preview(
          next,
          ExcludeChapterBodyLines(next.nodes.first.id, 2, 3),
        ),
      );
    }
  }

  testWidgets('清理后章节修改换算保留；无法换算的条目列出，确认后才放弃（CLEAN-097/098）', (t) async {
    final (state, library) = await open(t, 'v13-rebase-', {
      '可换算': blanks,
      '有冲突': blanks,
    });
    final ids = library.books.value.map((b) => b.id).toList();
    await t.runAsync(() async {
      // 1) 只有改名：全部换算，不需要确认。
      await edit(library, ids[0]);
      final cleanup = library.openCleanup(ids[0]);
      try {
        final plan = await cleanup.preview(jsonEncode(pipeline));
        expect(plan.total, greaterThan(0));
        final impact = await cleanup.impact(plan);
        expect(impact.edits, 1);
        expect(impact.skipped, isEmpty);
        expect(impact.checkpoint, false);
        final before =
            (state.manuscript.effectiveHistories[ids[0]]!['history'] as List).length;
        final receipt = await cleanup.apply(plan);
        expect(receipt.editsKept, 1);
        expect(receipt.editsDropped, 0);
        expect(state.cleanup.drafts[ids[0]], isNotNull);
        // 换算结果是章节历史中的新一步，可撤销。
        expect(
          (state.manuscript.effectiveHistories[ids[0]]!['history'] as List).length,
          before + 1,
        );
      } finally {
        cleanup.dispose();
      }
      final chapters = library.openChapters(ids[0]);
      final page = await chapters.read(0);
      expect(page.nodes.first.title, '第一章 改名');
      final body = await chapters.body(page, page.nodes.first.id, 0);
      expect(body.lines.any((l) => l.endsWith(' ')), false);
      expect(body.lines.join('\n'), isNot(contains('\n\n\n')));

      // 2) 改名 + 删除空行：删除的行被清理合并掉，无法换算。
      await edit(library, ids[1], exclude: true);
      final conflict = library.openCleanup(ids[1]);
      try {
        final plan = await conflict.preview(jsonEncode(pipeline));
        final impact = await conflict.impact(plan);
        expect(impact.edits, 2);
        expect(impact.skipped.length, 1);
        expect(impact.skipped.single.index, 1);
        expect(impact.skipped.single.action, '删除正文行');
        expect(impact.skipped.single.reason, '对应的行被清理删除或改动');
        final drafts = jsonEncode(state.cleanup.drafts);
        await expectLater(conflict.apply(plan), throwsFormatException);
        expect(jsonEncode(state.cleanup.drafts), drafts);
        final receipt = await conflict.apply(plan, dropSkipped: true);
        expect(receipt.editsKept, 1);
        expect(receipt.editsDropped, 1);
      } finally {
        conflict.dispose();
      }
      final chapters2 = library.openChapters(ids[1]);
      expect((await chapters2.read(0)).nodes.first.title, '第一章 改名');
    });
  });

  testWidgets('清理页：先出差异，后台核对章节修改；有冲突时确认放弃（CLEAN-097/099）', (t) async {
    size(t, const Size(1500, 1000));
    final (state, library) = await open(t, 'v13-cleanup-page-', {'冲突': blanks});
    final id = library.books.value.single.id;
    // 默认规则含“行尾空白”和“合并连续空行”。
    await t.runAsync(() => edit(library, id, exclude: true));
    await t.pumpWidget(
      app(
        CleanupPage(
          library: library,
          bookId: id,
          navigation: CleanupNavigationGuard(),
          onChecks: () {},
        ),
      ),
    );
    await until(t, () => find.text('清理所选项…').evaluate().isNotEmpty);
    await until(
      t,
      () => find.byKey(const Key('cleanup-impact-note')).evaluate().isNotEmpty,
    );
    expect(find.text('操作没有完成'), findsNothing);
    expect(find.text('正在准备清理预览…'), findsNothing);
    expect(find.textContaining('处章节修改无法保留'), findsOneWidget);
    await t.tap(find.text('清理所选项…'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('cleanup-apply')));
    await t.pumpAndSettle();
    expect(find.textContaining('章节修改并清理？'), findsOneWidget);
    expect(find.byKey(const Key('cleanup-dropped-edit-1')), findsOneWidget);
    await t.tap(find.text('放弃这些修改并清理'));
    await t.pump();
    await idle(t);
    await t.pumpAndSettle();
    expect(find.text('章节修改已随清理保留'), findsOneWidget);
    expect(find.text('章节修改已按确认放弃'), findsOneWidget);
    expect(state.cleanup.drafts[id], isNotNull);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('标题改为正文：修改后定位到这一行所在的章节并高亮，修改前选中原标题（CH-257）', (t) async {
    size(t, const Size(1400, 900));
    final (_, library) = await open(t, 'v13-demote-', {
      '降级': [for (var i = 1; i <= 34; i++) '第$i章 标题$i\n正文$i\n'].join(),
    });
    final id = library.books.value.single.id;
    final chapters = library.openChapters(id);
    late ChapterPage page;
    late ChapterEditPreview preview;
    late ChapterNode target;
    await t.runAsync(() async {
      page = await chapters.read(30);
      // 第 31 章是第二页的第一个标题：降级后它归入上一页的第 30 章。
      target = page.nodes.first;
      expect(target.title, '第31章 标题31');
      preview = await chapters.preview(page, DemoteChapterHeading(target.id));
    });
    await t.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => ChapterCandidateDialog(
                session: chapters,
                preview: preview,
                originalPage: page,
                title: '标题改为正文',
                explanation: '说明',
                initialOffset: page.offset,
                focusNodeId: target.id,
                focusLine: target.line,
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开'));
    await until(
      t,
      () => find.byKey(const Key('candidate-focus-line')).evaluate().isNotEmpty,
    );
    // 修改后：选中第 30 章，正文翻到被降级的那一行。
    expect(find.text('第30章 标题30'), findsWidgets);
    final focused = t.widget<DeskLineRow>(
      find.byKey(const Key('candidate-focus-line')),
    );
    expect(focused.text, '第31章 标题31');
    expect(focused.selected, true);
    // 修改前：选中原标题。
    await t.tap(find.text('修改前'));
    await until(
      t,
      () => find
          .descendant(of: find.byType(DeskLineRow), matching: find.text('正文31'))
          .evaluate()
          .isNotEmpty,
    );
    expect(t.takeException(), isNull);
    // “卷前正文”是普通按钮，不是标题样式的文字。
    expect(
      find.ancestor(of: find.text('卷前正文'), matching: find.byType(DeskButton)),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('排版预览：设置收为一行，阅读器设置在弹出面板，预览页更高（LAY-098/099）', (t) async {
    size(t, const Size(1500, 1000));
    final body = List.generate(80, (i) => '第$i段正文用于分页测试。' * 3).join('\n');
    final (state, library) = await open(t, 'v13-layout-', {
      '长章': '第一章 开始\n$body\n第二章 结束\n尾声\n',
    });
    await t.pumpWidget(
      app(
        LayoutPage(
          library: library,
          bookId: state.currentId,
          navigation: LayoutNavigationGuard(),
          pickPresetFile: () async => null,
          pickPresetDestination: () async => null,
          importCss: () async => null,
        ),
      ),
    );
    final settings = find.byKey(const ValueKey('layout-reader-settings'));
    await until(t, () => settings.evaluate().isNotEmpty);
    await idle(t);
    await t.pumpAndSettle();
    // 设置按钮显示当前设置；机型、章节与它在同一行。
    expect(find.textContaining('字号 8 · 窄边距 · 中行距'), findsOneWidget);
    final device = find.byKey(const ValueKey('layout-preview-device'));
    expect(
      (t.getCenter(device).dy - t.getCenter(settings).dy).abs(),
      lessThan(12),
    );
    expect(find.byKey(const ValueKey('layout-reader-panel')), findsNothing);
    // 预览页按剩余空间放大（屏幕上的实际尺寸，含缩放）：上沿紧跟设置行，
    // 下沿紧贴翻页条；V12 在同样窗口里只有 534 像素高，且上下各空出一大段。
    final page = t.getRect(find.byKey(const ValueKey('layout-preview-page')));
    final pager = t.getRect(find.byKey(const ValueKey('layout-preview-pages')));
    expect(page.height, greaterThan(760));
    expect(
      (page.top - t.getRect(settings).bottom) < 40 ||
          (pager.top - page.bottom) < 40,
      true,
    );
    // 弹出面板：调字号、校准。
    await t.tap(settings);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('layout-reader-panel')), findsOneWidget);
    await t.tap(find.byTooltip('大一档'));
    await t.pumpAndSettle();
    expect(
      t.widget<Text>(find.byKey(const ValueKey('layout-reader-level'))).data,
      '9',
    );
    await t.tap(find.byKey(const ValueKey('layout-reader-calibrate')));
    await t.pumpAndSettle();
    expect(find.text('按真机校准'), findsWidgets);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('书库：紧凑行、表头、状态只在需要时醒目，详情面板显示数量与入口（LIB-098–100）', (t) async {
    size(t, const Size(1500, 1000));
    final (state, library) = await open(t, 'v13-library-', {
      '甲书': '第一章 开始\n正文\n第二章 继续\n正文\n第四章 跳号\n正文\n第五章 结束\n正文\n',
      '乙书': '第一章 开始\n正文\n',
    });
    final ids = library.books.value.map((b) => b.id).toList();
    final first = library.books.value.firstWhere((b) => b.title == '甲书').id;
    await t.runAsync(() async {
      for (final id in ids) {
        final checks = library.openChecks(id);
        try {
          await checks.inspect();
        } finally {
          checks.dispose();
        }
      }
      library.selectBook(first);
    });
    String? revealed;
    await t.pumpWidget(
      app(
        LibraryPage(
          library: library,
          picker: _NoPicker(),
          viewState: LibraryViewState()..compact = true,
          onRevealSource: (path) async => revealed = path,
        ),
      ),
    );
    await idle(t);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-column-header')), findsOneWidget);
    for (final label in ['书名', '格式', '大小', '状态']) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('library-column-header')),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
    final row = t.getSize(find.byKey(ValueKey('library-row-$first')));
    // V14：列表封面放大到 48×64，行高 76。
    expect(row.height, lessThanOrEqualTo(76));
    // 甲书跳号：状态列显示待核对数量；数量来自检查报告，只算章节问题（V15 LIB-106）。
    final book = library.books.value.firstWhere((b) => b.id == first);
    final pending = book.pending!;
    expect(pending.chapters, greaterThan(0));
    expect(pending.checkedAt, isNotNull);
    expect(
      find.descendant(
        of: find.byKey(ValueKey('library-status-$first')),
        matching: find.text('待核对 ${pending.chapters}'),
      ),
      findsOneWidget,
    );
    // 当前书：“当前”标记；不再在每行重复“检查完成 · 有待核对项”。
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('检查完成 · 有待核对项'), findsNothing);
    // 详情面板（V14 精简）：一行写数量与检查时间，入口齐全，原文件位置只留文件夹图标。
    // V15：详情写章节问题数量，清理建议、书籍信息与最近检查时间分行列出。
    expect(find.text('章节问题 ${pending.chapters} 项'), findsOneWidget);
    expect(find.text('最近检查'), findsOneWidget);
    for (final page in ['chapters', 'information', 'layout', 'cleanup']) {
      expect(find.byKey(ValueKey('book-summary-open-$page')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('book-summary-path')), findsNothing);
    await t.tap(find.byTooltip('打开文件夹'));
    await t.pump();
    expect(revealed, book.path);
    expect(state.cleanup.drafts, isEmpty);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
