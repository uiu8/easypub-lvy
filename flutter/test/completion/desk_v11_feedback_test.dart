import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/body_compare_dialog.dart';
import 'package:easypub_desktop/desk/checks/batch_repair_dialog.dart';
import 'package:easypub_desktop/desk/checks/issue_browser.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/conversion/conversion_page.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/rules/rules_sheet.dart';
import 'package:easypub_desktop/desk/widgets.dart';

import 'package:easypub_desktop/application/library_service.dart';

class _NoPicker extends Fake implements BookFilePicker {}

class _Desktop extends Fake
    implements ConversionDesktop, OutputDirectoryDesktop {
  _Desktop(this.directory);
  final String directory;
  @override
  Future<String?> bundledConverter() async => null;
  @override
  Future<String> defaultOutputDirectory() async => directory;
}

/// V11：两章对照、识别规则说明与常用预设、转换页、排版机型预览、批量标记“不是标题”。
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

  Future<(PrototypeState, LegacyLibraryAdapter, Directory)> open(
    WidgetTester t,
    String prefix,
    Map<String, String> books, {
    Map<String, Object?> settings = const {},
    int? numericLines,
  }) async {
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late Directory root;
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp(prefix)).absolute;
      state = PrototypeState(settingsDirectory: '${root.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({
        'check_after_import': false,
        if (numericLines != null)
          'recognition_defaults': {
            ...await library.openRules(null).builtin(),
            'numeric_minimum_body_lines': numericLines,
          },
        ...settings,
      });
      for (final entry in books.entries) {
        final file = File('${root.path}/${entry.key}.txt')
          ..writeAsStringSync(entry.value);
        expect((await library.importFiles([file.path])).single.succeeded, true);
      }
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    return (state, library, root);
  }

  Widget app(Widget child) => MaterialApp(
    theme: deskTheme(),
    home: Scaffold(body: child),
  );

  group('两章正文对照默认两章（CH-247）', () {
    const nodes = [
      ChapterNode('a', '第1章 甲', 'chapter', 0, 1, true),
      ChapterNode('b', '第2章 乙', 'chapter', 0, 3, true),
      ChapterNode('c', '第456章 2k', 'chapter', 0, 5, true),
      ChapterNode('d', '第四百五十六章 别急', 'chapter', 0, 7, true),
      ChapterNode('e', '第2章 乙', 'chapter', 0, 9, true),
    ];
    test('编号相同、标题不同的两章也能配对', () {
      expect(chapterNumber('第四百五十六章 别急'), (456, '章'));
      expect(chapterNumber('第２回 甲'), (2, '回'));
      expect(chapterNumber('序章'), isNull);
      expect(defaultComparePair(nodes, [5]), (2, 3));
      // 问题位置落在章内正文：按所在章处理。
      expect(defaultComparePair(nodes, [6]), (2, 3));
      // 同标题优先于同编号。
      expect(defaultComparePair(nodes, [3]), (1, 4));
      // 两处位置直接取所在两章。
      expect(defaultComparePair(nodes, [9, 1]), (0, 4));
      // 无同标题、同编号：所在章与下一章。
      expect(defaultComparePair(nodes, [1]), (0, 1));
      expect(defaultComparePair(nodes.take(1).toList(), [1]), isNull);
    });

    testWidgets('章节行入口只给一处位置时，打开同编号的两章并可任选', (t) async {
      size(t, const Size(1400, 900));
      final (state, library, _) = await open(t, 'v11-compare-', {
        '重复编号': '第1章 甲\n甲文\n第2章 乙\n乙文一\n第2章 丙\n丙文二\n第3章 丁\n丁文\n',
      });
      final session = library.openChapters(state.currentId);
      late ChapterPage tree;
      await t.runAsync(() async => tree = await session.read(0));
      final yi = tree.nodes.firstWhere((n) => n.title == '第2章 乙');
      await t.pumpWidget(
        app(
          ChapterBodyCompareDialog(
            session: session,
            structure: tree,
            lines: [yi.line],
          ),
        ),
      );
      await idle(t);
      await t.pumpAndSettle();
      final choices = t
          .widgetList<DeskChoice<String>>(find.byType(DeskChoice<String>))
          .toList();
      expect(choices, hasLength(2));
      final byId = {for (final n in tree.nodes) n.id: n.title};
      expect(byId[choices[0].value], '第2章 乙');
      expect(byId[choices[1].value], '第2章 丙');
      // 下拉中可以选全书任一章。
      expect(choices[0].items!.length, tree.nodes.length);
      expect(find.textContaining('未找到两个可对照章节'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('问题详情“对比两章正文”：编号重复问题直接打开两处', (t) async {
      size(t, const Size(1400, 900));
      final (state, library, _) = await open(t, 'v11-compare-issue-', {
        '重复编号': '第1章 甲\n甲文\n第2章 乙\n乙文一\n第2章 丙\n丙文二\n第3章 丁\n丁文\n',
      });
      final session = library.openChapters(state.currentId);
      await t.pumpWidget(
        app(
          CheckIssueBrowser(session: session, enabled: true, onChapter: (_) {}),
        ),
      );
      await idle(t);
      final issue = find.textContaining('出现了两次');
      await until(t, () => issue.evaluate().isNotEmpty);
      await t.tap(issue.first);
      await idle(t);
      final button = find.byKey(const ValueKey('issue-compare-bodies'));
      await until(t, () => button.evaluate().isNotEmpty);
      expect(find.text('第一处'), findsWidgets);
      await t.tap(button);
      await until(
        t,
        () => find.byType(ChapterBodyCompareDialog).evaluate().isNotEmpty,
      );
      await idle(t);
      await t.pumpAndSettle();
      final titles = t
          .widgetList<DeskChoice<String>>(
            find.descendant(
              of: find.byType(ChapterBodyCompareDialog),
              matching: find.byType(DeskChoice<String>),
            ),
          )
          .map((c) => c.value)
          .toList();
      late ChapterPage tree;
      await t.runAsync(() async => tree = await session.read(0));
      final byId = {for (final n in tree.nodes) n.id: n.title};
      expect(titles.map((id) => byId[id]), ['第2章 乙', '第2章 丙']);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('识别规则：内置规则说明、以此为起点、说明问号与常用预设（CH-248–252）', (t) async {
    size(t, const Size(1500, 1000));
    final (state, library, _) = await open(t, 'v11-rules-', {
      '规则': '第一章 开始\n正文\n第二章 继续\n正文\n',
    });
    final rules = library.openRules(state.currentId);
    late Map<String, dynamic> info, base;
    await t.runAsync(() async {
      info = await rules.builtinDescription();
      base = await rules.builtin();
      final reference = info['chapter']['reference_regex'] as String;
      Future<Map?> sample(Map<String, Object?> overrides, String line) async =>
          (await rules.sample({...base, ...overrides}, line))['match'] as Map?;
      // 参考正则可被识别器接受，并覆盖内置识别形式。
      for (final line in ['第十二章 开始', '序章', '第二卷 风起', '12章 测试']) {
        expect(await sample({'chapter_pattern': reference}, line), isNotNull);
      }
      expect(info['numeric']['regex'], contains('(?<number>'));
      // 三套常用预设都能被识别器接受，并按预期匹配。
      final hua = commonRulePresets['常用：第X话 / 第X集']!;
      final m1 = await sample(hua, '第12话 风起');
      expect((m1!['role'], m1['number'], m1['title']), ('chapter', 12, '风起'));
      expect((await sample(hua, '第二卷 风起'))!['role'], 'volume');
      final en = commonRulePresets['常用：英文 Chapter N']!;
      final m2 = await sample(en, 'Chapter 3: The Road');
      expect(
        (m2!['role'], m2['number'], m2['title']),
        ('chapter', 3, 'The Road'),
      );
      expect((await sample(en, 'Volume 2'))!['role'], 'volume');
      expect(
        await sample(commonRulePresets['常用：纯数字标题']!, '238：以命换伤'),
        isNotNull,
      );
    });
    await t.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showChapterRulesDialog(
              context,
              service: library,
              bookId: state.currentId,
            ),
            child: const Text('打开规则'),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开规则'));
    final builtin = find.byKey(const ValueKey('rules-builtin-chapter'));
    await until(t, () => builtin.evaluate().isNotEmpty);
    await idle(t);
    // 说明问号：层级、错字表、预设。
    for (final key in ['层级与高级表达式', '编号错字表', '规则预设']) {
      expect(find.byKey(ValueKey('rules-help-$key')), findsOneWidget);
    }
    final help = t.widget<DeskHelp>(
      find.byKey(const ValueKey('rules-help-编号错字表')),
    );
    expect(help.message, contains('编号相差 2'));
    expect(help.message, contains('久=九'));
    await t.tap(builtin);
    await t.pumpAndSettle();
    final regex = t.widget<SelectableText>(
      find.byKey(const ValueKey('rules-builtin-regex')),
    );
    expect(regex.data, info['chapter']['reference_regex']);
    expect(find.text('不算标题（正文排除）'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('rules-builtin-seed')));
    await t.pumpAndSettle();
    final field = t.widget<TextField>(
      find.byKey(const ValueKey('rules-chapter_pattern')),
    );
    expect(field.controller!.text, info['chapter']['reference_regex']);
    expect(find.textContaining('正文排除'), findsWidgets);
    // 常用预设：载入后来源显示预设名。
    await t.tap(find.text('规则预设'));
    await t.pumpAndSettle();
    await t.tap(find.text('载入预设'));
    await t.pumpAndSettle();
    await t.tap(find.text('常用：第X话 / 第X集').last);
    // 编辑台选择框先关菜单、下一帧才回调 onChanged，先推一帧再等载入完成。
    await t.pump();
    await idle(t);
    await t.pumpAndSettle();
    expect(find.textContaining('规则预设“常用：第X话 / 第X集”'), findsOneWidget);
    expect(
      t
          .widget<TextField>(
            find.byKey(const ValueKey('rules-chapter_pattern')),
          )
          .controller!
          .text,
      commonRulePresets['常用：第X话 / 第X集']!['chapter_pattern'],
    );
    // 内置预设不能改名或删除。
    expect(
      t.widget<DeskButton>(find.widgetWithText(DeskButton, '删除')).onPressed,
      isNull,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('漏识别标题批量标记“不是标题”：只写审阅结论，不改正文（CHK-052）', (t) async {
    size(t, const Size(1280, 860));
    final (state, library, _) = await open(t, 'v11-mark-', {
      '数字章节':
          '番外：生日\n原有番外正文\n${List.generate(6, (i) => '${238 + i}：标题$i\n正文$i 第一段\n第二段\n第三段\n').join()}',
    }, numericLines: 3);
    final session = library.openChapters(state.currentId);
    await t.pumpWidget(
      app(
        CheckIssueBrowser(session: session, enabled: true, onChapter: (_) {}),
      ),
    );
    await idle(t);
    final batch = find.byKey(const ValueKey('batch-repair'));
    await until(t, () => batch.evaluate().isNotEmpty);
    await t.tap(batch);
    await until(t, () => find.byType(BatchRepairDialog).evaluate().isNotEmpty);
    await idle(t);
    // V23：原“全部取消”按钮改为表头三态勾选框（默认全选，点一下全部取消）。
    await t.tap(find.byKey(const ValueKey('select-all')));
    await t.pump();
    final boxes = find.descendant(
      of: find.byType(BatchRepairDialog),
      matching: find.byType(Checkbox),
    );
    await t.tap(boxes.at(1));
    await t.tap(boxes.at(2));
    await t.pump();
    expect(find.text('标记所选 2 项为不是标题'), findsOneWidget);
    late int before;
    await t.runAsync(() async => before = (await session.read(0)).total);
    await t.tap(find.byKey(const ValueKey('batch-mark-normal')));
    await until(t, () => find.byType(BatchRepairDialog).evaluate().isEmpty);
    await idle(t);
    await t.runAsync(() async {
      final tree = await session.read(0);
      expect(tree.total, before, reason: '只写审阅结论，不改章节');
      final issues = await session.issues(tree, 0, effective: true);
      final decided = issues.items.where(
        (i) => i.category == 'unrecognized-heading' && i.decision != null,
      );
      expect(decided, hasLength(2));
      expect(decided.every((i) => i.decision == 'confirmed_normal'), true);
    });
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('转换页：列表随高度、全选/只看已选、本次输出汇总、托盘不重复（OUT-063–067）', (t) async {
    size(t, const Size(1600, 1000));
    final (state, library, root) = await open(t, 'v11-conversion-', {
      '甲书': '第一章 甲\n甲文\n',
      '乙书': '第一章 乙\n乙文\n',
      '丙书': '第一章 丙\n丙文\n',
    });
    library.checkBooks(library.books.value.map((b) => b.id).toSet(), true);
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
    await t.pumpWidget(
      RewriteApp(
        library: library,
        picker: _NoPicker(),
        initialLocation: '/conversion',
        conversionDesktop: _Desktop(root.path),
      ),
    );
    await until(t, () => find.byType(ConversionPage).evaluate().isNotEmpty);
    await idle(t);
    await t.pumpAndSettle();
    final count = find.byKey(const ValueKey('conversion-selected-count'));
    expect(t.widget<Text>(count).data, '已选 3 / 共 3');
    final files = find.byKey(const ValueKey('conversion-summary-files'));
    expect(
      t.widget<Text>(files).data,
      matches(RegExp(r'^本次将生成 3 个 \.\w+ 文件$')),
    );
    // 托盘在转换页不重复格式与输出位置。
    expect(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('quick-format-'),
      ),
      findsNothing,
    );
    // V16：全选改为勾选框，全部已选时再点清空（OUT-072）。
    await t.tap(find.byKey(const ValueKey('conversion-select-all')));
    await t.pump();
    expect(t.widget<Text>(count).data, '已选 0 / 共 3');
    expect(t.widget<Text>(files).data, '本次输出');
    await t.tap(find.byKey(const ValueKey('conversion-select-all')));
    await t.pump();
    expect(t.widget<Text>(count).data, '已选 3 / 共 3');
    // 取消一本后“只看已选”只剩两行。
    await t.tap(find.text('乙书'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('conversion-only-selected')));
    await t.pump();
    expect(find.text('乙书'), findsNothing);
    expect(find.text('甲书'), findsWidgets);
    expect(t.widget<Text>(files).data, matches(RegExp(r'^本次将生成 2 个 ')));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  });

  group('排版预览机型与分页（LAY-092–095）', () {
    test('机型表与自定义范围、偏好序列化', () {
      expect(kindleDevices, hasLength(12));
      expect(kindleDevices.map((d) => d.id).toSet(), hasLength(12));
      expect(customKindleDevice(300, 1000, 300), isNull);
      expect(customKindleDevice(1000, 1000, 700), isNull);
      final custom = customKindleDevice(1200, 1600, 300)!;
      // V118：所有机型按原生分辨率排版，视口等于分辨率。
      expect((custom.viewportWidth, custom.viewportHeight), (1200, 1600));
      final choice = PreviewDeviceChoice.decode(
        const PreviewDeviceChoice(id: 'scribe').encode(),
      );
      expect(choice.device.id, 'scribe');
      expect(PreviewDeviceChoice.decode('损坏').device.id, defaultKindleDeviceId);
    });

    testWidgets('分页保留全部正文，续排部分不缩进', (t) async {
      final style = PreviewStyle(
        title: const TextStyle(fontSize: 22),
        body: const TextStyle(fontSize: 16, height: 1.6),
        align: TextAlign.justify,
        indent: 32,
        paragraphSpacing: 8,
        titleSpacing: 20,
        padding: const EdgeInsets.all(24),
      );
      final paragraphs = [
        for (var i = 0; i < 40; i++) '第$i段${'很长的正文内容' * (i % 7 + 3)}',
      ];
      final pages = paginatePreview(
        title: '第一章 测试',
        paragraphs: paragraphs,
        style: style,
        page: const Size(360, 486),
      );
      expect(pages.length, greaterThan(3));
      final pieces = pages.expand((p) => p).toList();
      expect(pieces.first.title, true);
      expect(
        pieces.where((p) => !p.title).map((p) => p.text).join(),
        paragraphs.join(),
      );
      expect(pieces.where((p) => !p.indent && !p.title), isNotEmpty);
      final bigger = paginatePreview(
        title: '第一章 测试',
        paragraphs: paragraphs,
        style: style,
        page: const Size(465, 620),
      );
      expect(bigger.length, lessThan(pages.length));
    });

    testWidgets('排版页：机型选择、翻页、偏好写入设置目录、缩进说明、顶部操作固定', (t) async {
      size(t, const Size(1500, 1000));
      final body = List.generate(
        80,
        (i) => '这是第$i段正文，用来检查分页是否按机型版面切分。' * 3,
      ).join('\n');
      final (state, library, root) = await open(t, 'v11-layout-', {
        '长章': '第一章 开始\n$body\n第二章 结束\n尾声正文\n',
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
      final pages = find.byKey(const ValueKey('layout-preview-pages'));
      await until(t, () => pages.evaluate().isNotEmpty);
      await idle(t);
      await t.pumpAndSettle();
      final first = t.widget<Text>(pages).data!;
      expect(first, startsWith('第 1 / '));
      final total = int.parse(RegExp(r'/ (\d+) 页').firstMatch(first)![1]!);
      expect(total, greaterThan(1));
      await t.tap(find.text('下一页'));
      await t.pump();
      expect(t.widget<Text>(pages).data, '第 2 / $total 页');
      expect(
        find.byKey(const ValueKey('layout-settings-actions')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('layout-help-fullwidth_indent')),
        findsOneWidget,
      );
      expect(
        t
            .widget<DeskHelp>(
              find.byKey(const ValueKey('layout-help-paragraph_indent')),
            )
            .message,
        contains('叠加'),
      );
      // 换成 Scribe：版面更大，页数减少，并写入设置目录。
      t
          .widget<DeskChoice<String>>(
            find.byKey(const ValueKey('layout-preview-device')),
          )
          .onChanged!('scribe');
      await t.pumpAndSettle();
      // V13：分辨率移到机型的悬停说明里。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Tooltip &&
              (w.message ?? '').contains('1860 × 2480 · 300 PPI'),
        ),
        findsOneWidget,
      );
      final scribe = int.parse(
        RegExp(r'/ (\d+) 页').firstMatch(t.widget<Text>(pages).data!)![1]!,
      );
      expect(scribe, lessThan(total));
      final file = File('${root.path}/settings/layout-preview-device.json');
      await until(t, () => file.existsSync());
      expect(file.readAsStringSync(), contains('scribe'));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  });
}
