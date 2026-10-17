import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/rule_catalog_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/checks/checks_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/rules/rules_page.dart';
import 'package:easypub_desktop/desk/widgets.dart';

/// V64：检查页进入规则页（CH-279）与规则页改版（CH-280），真实 DLL。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  Future<(PrototypeState, LegacyLibraryAdapter, String)> setup(
    WidgetTester t,
    String prefix,
  ) async {
    t.view.physicalSize = const Size(1280, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp(prefix))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      // 第二章后直接是第四章：一处编号跳跃；另有一处系统提示和一组七言。
      final file = File('$root/雾港.txt')
        ..writeAsStringSync(
          '第一章 雾起\n　　港口的雾从傍晚开始往岸上爬。\n【叮！新手礼包已发放。】\n'
          '第二章 旧码头\n　　天亮了。\n'
          '第四章 远航\n　　船离开了码头。\n',
        );
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    return (state, library, id);
  }

  Future<void> until(WidgetTester t, bool Function() ready, String what) async {
    for (var i = 0; i < 600; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (ready()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    fail('未就绪：$what');
  }

  test('问题类型对应的规则编号', () {
    expect(chapterIssueRule('number-gap', null), 'check.number_gap');
    expect(
      chapterIssueRule('number-reset', 'repeated-number'),
      'check.number_reset.repeated_number',
    );
    expect(
      chapterIssueRule('number-reset', 'number-reversal'),
      'check.number_reset.number_reversal',
    );
    expect(
      chapterIssueRule('missing-heading-prefix', null),
      'check.missing_heading_prefix',
    );
  });

  testWidgets('检查页：顶栏“规则”按钮与问题类型名都能打开规则页', (t) async {
    final (_, library, id) = await setup(t, 'v64-checks-');
    final rules = <String?>[];
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: BookChecksPage(
            library: library,
            bookId: id,
            onRepair: (_) {},
            onCatalog: () {},
            onChapter: (_) {},
            onCleanup: () {},
            onRules: rules.add,
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('checks-rules'));
    await until(t, () => button.evaluate().isNotEmpty, '规则按钮');
    await t.tap(button);
    expect(rules, [null]);

    // 没有检查结果时先检查本书。
    final link = find.byKey(const ValueKey('issue-rule-link'));
    if (link.evaluate().isEmpty) {
      final check = find.widgetWithText(DeskButton, '检查本书');
      await until(
        t,
        () =>
            check.evaluate().isNotEmpty &&
            t.widget<DeskButton>(check.first).onPressed != null,
        '检查本书可用',
      );
      await t.tap(check.first);
    }
    await until(t, () => link.evaluate().isNotEmpty, '问题详情的类型名');
    await t.tap(link);
    expect(rules.last, 'check.number_gap');
    expect(t.takeException(), isNull);
  });

  testWidgets('规则页：定位到问题对应规则、页签、筛选、搜索、回到检查', (t) async {
    final (_, library, id) = await setup(t, 'v64-rules-');
    var back = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: RulesPage(
            library: library,
            bookId: id,
            focusRule: 'check.number_gap',
            onBack: () => back++,
            onOpenLocation: (_) {},
            onOpenSettings: (_) {},
          ),
        ),
      ),
    );
    String status() => t
        .widget<DeskTag>(
          find.descendant(
            of: find.byKey(const ValueKey('rules-status')),
            matching: find.byType(DeskTag),
          ),
        )
        .text;
    await until(t, () => status().startsWith('已统计'), '统计完成');

    // 打开即切到“章节检查”页签，展开编号跳跃，命中 1 个问题。
    expect(find.byKey(const ValueKey(('rule-group', '章节检查'))), findsOneWidget);
    expect(find.byKey(const ValueKey(('rule-group', '文本清理'))), findsNothing);
    expect(
      find.byKey(const ValueKey(('rule-details', 'check.number_gap'))),
      findsOneWidget,
    );
    final gap = find.byKey(const ValueKey(('rule-row', 'check.number_gap')));
    expect(
      find.descendant(of: gap, matching: find.text('1 个问题')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: gap, matching: find.byType(RuleSwitch)),
      findsOneWidget,
    );

    // 筛选“有命中”：只剩编号跳跃；“需配置”：章节检查没有需配置的规则。
    await t.tap(find.byKey(const ValueKey('rules-filter-hit')));
    await t.pump();
    expect(gap, findsOneWidget);
    expect(
      find.byKey(const ValueKey(('rule-row', 'check.duplicate_content'))),
      findsNothing,
    );
    await t.tap(find.byKey(const ValueKey('rules-filter-config')));
    await t.pump();
    expect(find.byKey(const ValueKey('rules-empty')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('rules-filter-all')));
    await t.pump();

    // 搜索跨页签：“系统提示”在排版识别组。
    await t.enterText(find.byKey(const ValueKey('rules-search')), '系统提示');
    await t.pump();
    expect(find.byKey(const ValueKey(('rule-group', '排版识别'))), findsOneWidget);
    expect(find.byKey(const ValueKey(('rule-group', '章节检查'))), findsNothing);
    expect(find.text('1 处'), findsWidgets);

    // 点页签清空搜索并切换。
    await t.tap(find.byKey(const ValueKey('rules-tab-0')));
    await t.pump();
    expect(find.byKey(const ValueKey(('rule-group', '文本清理'))), findsOneWidget);
    expect(find.byKey(const ValueKey(('rule-group', '排版识别'))), findsNothing);

    await t.tap(find.byKey(const ValueKey('rules-back')));
    expect(back, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('规则页：细分项定位到所属规则并展开', (t) async {
    final (_, library, id) = await setup(t, 'v64-child-');
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: RulesPage(
            library: library,
            bookId: id,
            focusRule: 'check.number_reset.repeated_number',
            onOpenLocation: (_) {},
            onOpenSettings: (_) {},
          ),
        ),
      ),
    );
    await until(
      t,
      () => find
          .byKey(const ValueKey(('rule-details', 'check.number_reset')))
          .evaluate()
          .isNotEmpty,
      '展开编号回退或重复',
    );
    expect(
      find.byKey(
        const ValueKey(('rule-child', 'check.number_reset.repeated_number')),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('rules-back')), findsNothing);
    expect(t.takeException(), isNull);
  });
}
