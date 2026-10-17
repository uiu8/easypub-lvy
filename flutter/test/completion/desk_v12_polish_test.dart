import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/checks/cleanup_findings.dart';
import 'package:easypub_desktop/desk/checks/issue_browser.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/library/library_view_state.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/rules/rules_sheet.dart';

class _NoPicker extends Fake implements BookFilePicker {}

/// V12：多选、检查页分组与进度、清理结果显示、非标题词库、Kindle 校准。
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
    for (var i = 0; i < 400; i++) {
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

  testWidgets('书库：勾选列拖动连选、拖动框选、Ctrl 点击、Ctrl+A 与 Esc（LIB-095/096）', (t) async {
    size(t, const Size(1500, 1000));
    final (_, library) = await open(t, 'v12-select-', {
      for (final n in ['甲', '乙', '丙', '丁', '戊']) '$n书': '第一章 $n\n$n文\n',
    });
    await t.pumpWidget(
      app(
        LibraryPage(
          library: library,
          picker: _NoPicker(),
          viewState: LibraryViewState()..compact = true,
        ),
      ),
    );
    await idle(t);
    await t.pumpAndSettle();
    final ids = library.books.value.map((b) => b.id).toList();
    Set<String> checked() => library.selection.value.selected;
    Offset boxOf(int i) =>
        t.getCenter(find.byKey(ValueKey('library-check-${ids[i]}')));
    Offset titleOf(int i) => t.getCenter(
      find
          .descendant(
            of: find.byKey(ValueKey('library-row-${ids[i]}')),
            matching: find.byType(Text),
          )
          .first,
    );
    // 1) 在勾选列从第 1 行拖到第 3 行：三行都被勾选。
    final paint = await t.startGesture(
      boxOf(0),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await t.pump();
    await paint.moveTo(boxOf(1));
    await t.pump();
    await paint.moveTo(boxOf(2));
    await t.pump();
    await paint.up();
    await t.pump();
    expect(checked(), {ids[0], ids[1], ids[2]});
    // 2) 再从第 2 行勾选列拖到第 3 行：第 2 行原为已勾选，因此这两行取消。
    final unpaint = await t.startGesture(
      boxOf(1),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await t.pump();
    await unpaint.moveTo(boxOf(2));
    await t.pump();
    await unpaint.up();
    await t.pump();
    expect(checked(), {ids[0]});
    // 3) Esc 清空；从第 4 行的标题处拖到第 5 行：选框加入这两行，并画出选框。
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(checked(), isEmpty);
    final band = await t.startGesture(
      titleOf(3),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await t.pump();
    await band.moveTo(titleOf(4) + const Offset(0, 8));
    await t.pump();
    expect(find.byKey(const ValueKey('drag-select-band')), findsOneWidget);
    await band.up();
    await t.pump();
    expect(checked(), {ids[3], ids[4]});
    expect(find.byKey(const ValueKey('drag-select-band')), findsNothing);
    // 4) Ctrl+点击行：单独加选；Ctrl+A 全选。
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.tapAt(titleOf(0));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(checked(), {ids[0], ids[3], ids[4]});
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(checked(), ids.toSet());
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('检查页：按“认全 / 去重 / 归位”分组、组可折叠、顶部“已核对”进度（CHK-053/054）', (t) async {
    size(t, const Size(1400, 900));
    final (state, library) = await open(t, 'v12-groups-', {
      '分组':
          '第1章 甲\n甲文\n第2章 乙\n乙文\n第2章 乙\n乙文\n第5章 戊\n戊文\n1.请不要让前桌坐着\n${List.generate(4, (i) => '正文$i').join('\n')}\n第6章 己\n己文\n',
    });
    final session = library.openChapters(state.currentId);
    await t.pumpWidget(
      app(
        CheckIssueBrowser(session: session, enabled: true, onChapter: (_) {}),
      ),
    );
    await idle(t);
    final group0 = find.byKey(const ValueKey('check-issue-group-0'));
    await until(t, () => group0.evaluate().isNotEmpty);
    await idle(t);
    late ChapterIssuePage page;
    late ChapterPage tree;
    await t.runAsync(() async {
      tree = await session.read(0);
      page = await session.issues(tree, 0, effective: true);
    });
    // 结果已按组排序：组号不递减。
    final groups = page.items.map((i) => chapterIssueGroupOf(i.category));
    expect(groups.toList(), [...groups]..sort());
    expect(page.reviewed, 0);
    final progress = find.byKey(const ValueKey('check-issue-progress'));
    expect(t.widget<Text>(progress).data, '已核对 0 / ${page.unfilteredTotal}');
    expect(
      find.byKey(const ValueKey('check-issue-progress-bar')),
      findsOneWidget,
    );
    // 折叠第一组：该组的条目不再显示。
    final firstId = page.items.first.id;
    expect(find.byKey(ValueKey('check-issue-$firstId')), findsOneWidget);
    await t.tap(group0);
    await t.pump();
    expect(find.byKey(ValueKey('check-issue-$firstId')), findsNothing);
    await t.tap(group0);
    await t.pump();
    // 审阅一项后，进度增加。
    await t.tap(find.byKey(ValueKey('check-issue-$firstId')));
    await idle(t);
    await t.tap(find.byKey(ValueKey('review-$firstId')));
    await t.pumpAndSettle();
    await t.tap(find.text('本项已核实正常').last);
    await until(
      t,
      () => t.widget<Text>(progress).data == '已核对 1 / ${page.unfilteredTotal}',
    );
    // 底部按钮分组显示；“审阅此项”与按钮同高。
    expect(find.byKey(const ValueKey('issue-actions')), findsOneWidget);
    final chip = t.getSize(
      find
          .ancestor(of: find.text('审阅此项'), matching: find.byType(Container))
          .first,
    );
    expect(chip.height, 36);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('检查页“文本清理”：按规则分组，空行与空白用标记显示（CHK-055）', (t) async {
    size(t, const Size(1200, 900));
    const items = [
      CleanupCheckItem(266, 'collapse_blank_lines', '', null),
      CleanupCheckItem(475, 'collapse_blank_lines', '', null),
      CleanupCheckItem(12, 'trim_trailing_spaces', '他说。  ', '他说。'),
      CleanupCheckItem(30, 'remove_ad_lines', '本章完，求月票', null, candidate: true),
    ];
    final located = <int>[];
    await t.pumpWidget(
      app(
        SingleChildScrollView(
          child: CleanupFindingsView(items: items, onLocate: located.add),
        ),
      ),
    );
    expect(find.text('合并连续空行'), findsWidgets);
    expect(find.text('行尾空白'), findsWidgets);
    expect(find.text('广告候选'), findsWidgets);
    expect(find.text('空行'), findsNWidgets(2));
    expect(find.textContaining(r'"\n"'), findsNothing);
    expect(find.text('需人工判断'), findsOneWidget);
    // 行尾空白：删掉的空格用 · 标出。
    expect(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains('··'),
      ),
      findsOneWidget,
    );
    await t.tap(find.byKey(const ValueKey('cleanup-filter-行尾空白')));
    await t.pump();
    expect(find.text('空行'), findsNothing);
    await t.tap(find.byTooltip('在清理页定位此行'));
    expect(located, [12]);
    // 检查报告持久化时保留结构化结果。
    final report = BookCheckReport.fromJson(
      BookCheckReport(
        'g',
        [CheckDomain('cleanup', '文本清理', 's', 'd', const [], cleanup: items)],
        null,
        '',
        0,
      ).toJson(),
    );
    expect(report.domains.single.cleanup.map((c) => c.line), [
      266,
      475,
      12,
      30,
    ]);
    expect(report.domains.single.cleanup.last.candidate, true);
  });

  testWidgets('非标题词库：从审阅加入后打开识别规则面板，识别器排除命中行（CH-253–255）', (t) async {
    size(t, const Size(1500, 1000));
    final (state, library) = await open(t, 'v12-phrases-', {
      '词库': '第一章 开始\n正文\n第二章 继续\n正文\n',
    });
    final rules = library.openRules(state.currentId);
    await t.runAsync(() async {
      final base = await rules.builtin();
      final hit = await rules.sample({
        ...base,
        'non_heading': '两章合一章',
      }, '两章合一章，更比两章强！');
      expect(hit['match'], isNull);
      final forced = await rules.sample({...base, 'force_heading': '楔子'}, '楔子');
      expect((forced['match'] as Map)['role'], 'chapter');
    });
    await t.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showChapterRulesDialog(
              context,
              service: library,
              bookId: state.currentId,
              appendNonHeading: '两章合一章',
            ),
            child: const Text('打开规则'),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开规则'));
    final field = find.byKey(const ValueKey('rules-non_heading'));
    await until(t, () => field.evaluate().isNotEmpty);
    await idle(t);
    expect(t.widget<TextField>(field).controller!.text, '两章合一章');
    expect(find.textContaining('已把“两章合一章”加入非标题词库'), findsOneWidget);
    expect(find.byKey(const ValueKey('rules-help-非标题词库与标题词库')), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  group('Kindle 预览校准（LAY-096）', () {
    test('KPW5 实测档位、推算档位、机型换算与真机校准', () {
      const kpw5 = PreviewDeviceChoice(id: 'kpw5');
      final m8 = readerMetrics(kpw5);
      // 实测：字号 8 时每行约 16 字（窄边距）。
      final width =
          390 -
          2 *
              readerSideMargin(
                kindleDevices.firstWhere((d) => d.id == 'kpw5'),
                'narrow',
              );
      expect((width / m8.fontPx).round(), 16);
      expect(m8.measured, true);
      expect(m8.note, '按 KPW5 实测');
      final m4 = readerMetrics(kpw5.copyWith(level: 4));
      final m12 = readerMetrics(kpw5.copyWith(level: 12));
      expect((width / m4.fontPx).round(), 25);
      expect((width / m12.fontPx).round(), 9);
      final m6 = readerMetrics(kpw5.copyWith(level: 6));
      expect(m6.measured, false);
      expect(m6.fontPx, inExclusiveRange(m4.fontPx, m8.fontPx));
      // 宽边距每行字数更少；书内字号放大也是推算。
      expect(readerMetrics(kpw5.copyWith(margin: 'wide')).measured, false);
      expect(
        readerMetrics(kpw5, bookScale: 1.2).fontPx,
        closeTo(m8.fontPx * 1.2, .01),
      );
      // 用户校准：按输入的每行字数排版，并记入偏好。
      final calibrated = kpw5.copyWith(
        level: 6,
        calibrations: {'kpw5:6:narrow:medium': (20, 14)},
      );
      final mc = readerMetrics(calibrated);
      expect((width / mc.fontPx).round(), 20);
      expect(mc.note, '按真机校准');
      final round = PreviewDeviceChoice.decode(calibrated.encode());
      expect(round.calibrations['kpw5:6:narrow:medium'], (20, 14));
      expect(round.level, 6);
    });

    testWidgets('排版页：阅读器设置与按真机校准', (t) async {
      size(t, const Size(1500, 1000));
      final body = List.generate(60, (i) => '第$i段正文用于分页测试。' * 3).join('\n');
      final (state, library) = await open(t, 'v12-reader-', {
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
      expect(find.text('按固件推算'), findsOneWidget);
      // V13：阅读器设置收进弹出面板，先打开面板再校准。
      await t.tap(settings);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('layout-reader-calibrate')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('calibrate-line')), '18');
      await t.enterText(find.byKey(const ValueKey('calibrate-page')), '13');
      await t.tap(find.byKey(const ValueKey('calibrate-save')));
      await t.pumpAndSettle();
      expect(find.text('按真机校准'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('按钮提示与文字相同时不弹出（V12）', (t) async {
    await t.pumpWidget(
      app(
        Column(
          children: [
            DeskButton('定位章节', onPressed: () {}),
            DeskButton('批量修复', tooltip: '一次处理全部', onPressed: () {}),
          ],
        ),
      ),
    );
    final same = t.widget<Tooltip>(
      find.ancestor(of: find.text('定位章节'), matching: find.byType(Tooltip)),
    );
    expect(same.triggerMode, TooltipTriggerMode.manual);
    final other = t.widget<Tooltip>(
      find.ancestor(of: find.text('批量修复'), matching: find.byType(Tooltip)),
    );
    expect(other.triggerMode, isNull);
  });
}
