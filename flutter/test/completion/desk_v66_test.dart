import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/rules/rules_page.dart';

/// V66：规则页开关接通（CH-282），真实 DLL；后端为 V65 的 settings / previewToggles / applyToggles。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  late String root;
  Future<(PrototypeState, LegacyLibraryAdapter, String)> setup(
    WidgetTester t,
    String prefix, {
    List<Map<String, dynamic>>? cleanup,
  }) async {
    t.view.physicalSize = const Size(1280, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp(prefix)).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({
        'check_after_import': false,
        'automatic_cleanup_pipeline': ?cleanup,
      });
      final file = File('$root/雾港.txt')
        ..writeAsStringSync(
          '第一章 雾起\n　　港口的雾从傍晚开始往岸上爬。\n【叮！新手礼包已发放。】\n'
          '【请收藏本站】\n床前明月光，疑是地上霜\n春风又绿江南岸，明月何时照我还。\n'
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
    final shown = [
      for (final key in ['rules-status', 'rules-pending-text'])
        for (final e
            in find
                .descendant(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(Text),
                )
                .evaluate())
          (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText(),
    ];
    fail('未就绪：$what；页面：$shown');
  }

  Finder toggle(String id) => find.byKey(ValueKey(('rule-toggle', id)));
  bool canToggle(WidgetTester t, String id) =>
      toggle(id).evaluate().isNotEmpty &&
      t.widget<InkWell>(toggle(id)).onTap != null;
  Finder row(String id) => find.byKey(ValueKey(('rule-row', id)));
  Future<void> openTab(WidgetTester t, String title) async {
    await t.tap(
      find.byKey(
        ValueKey('rules-tab-${ruleGroups.indexWhere((g) => g.$3 == title)}'),
      ),
    );
    await t.pump();
  }

  Widget page(LegacyLibraryAdapter library, String id, {String? focus}) =>
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: RulesPage(
            library: library,
            bookId: id,
            focusRule: focus,
            onOpenLocation: (_) {},
            onOpenSettings: (_) {},
          ),
        ),
      );

  testWidgets('本书：暂存、预览、返回修改、确认应用、与默认不同、锁定项与联动标签', (t) async {
    // 自动检查的清理配置：句中换行最短 1 字，会把两句七言合成一行（与 Rust 联动测试同一组合）。
    final (_, library, id) = await setup(
      t,
      'v66-book-',
      cleanup: [
        {'kind': 'join_hard_wraps', 'min_chars': 1, 'mode': 'chinese'},
      ],
    );
    await t.pumpWidget(page(library, id, focus: 'check.number_gap'));
    await until(
      t,
      () =>
          find.textContaining('已统计').evaluate().isNotEmpty &&
          canToggle(t, 'check.number_gap'),
      '统计与开关状态',
    );
    expect(
      find.descendant(
        of: row('check.number_gap'),
        matching: find.text('1 个问题'),
      ),
      findsOneWidget,
    );

    // 暂存后再点一次即取消。
    await t.tap(toggle('check.number_gap'));
    await t.pump();
    expect(find.text('1 项改动待应用 · 本书'), findsOneWidget);
    expect(
      find.descendant(
        of: row('check.number_gap'),
        matching: find.textContaining('待应用'),
      ),
      findsOneWidget,
    );
    await t.tap(toggle('check.number_gap'));
    await t.pump();
    expect(find.byKey(const ValueKey('rules-pending')), findsNothing);

    // 预览 → 返回修改：改动仍在暂存。
    await t.tap(toggle('check.number_gap'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('rules-preview')));
    final back = find.byKey(const ValueKey('rule-preview-back'));
    await until(t, () => back.evaluate().isNotEmpty, '预览对话框');
    expect(find.text('编号跳跃：开启 → 关闭'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('rule-preview-no-chapter')),
      findsOneWidget,
      reason: '只关检查，不改标题',
    );
    await t.tap(back);
    await until(t, () => back.evaluate().isEmpty, '对话框关闭');
    expect(find.text('1 项改动待应用 · 本书'), findsOneWidget);

    // 确认应用：写入本书，标“与新书默认不同”，重新统计后显示“开启会命中”。
    await t.tap(find.byKey(const ValueKey('rules-preview')));
    final apply = find.byKey(const ValueKey('rule-preview-apply'));
    await until(t, () => apply.evaluate().isNotEmpty, '预览对话框');
    await t.tap(apply);
    await until(
      t,
      () => find.textContaining('已应用 1 项改动').evaluate().isNotEmpty,
      '应用完成',
    );
    await until(
      t,
      () =>
          find
              .descendant(
                of: row('check.number_gap'),
                matching: find.text('开启会命中 1 个问题'),
              )
              .evaluate()
              .isNotEmpty &&
          find
              .descendant(
                of: row('check.number_gap'),
                matching: find.textContaining('与新书默认不同'),
              )
              .evaluate()
              .isNotEmpty,
      '重新统计与已改标记',
    );

    // 锁定项：基础章标题不能关。
    await openTab(t, '章节识别');
    expect(toggle('chapter.recognize.chapter'), findsOneWidget);
    expect(canToggle(t, 'chapter.recognize.chapter'), false);

    // 联动标签与统计一致：页面显示的标签数 = 统计里 affects 的条数。
    final service = library.openRuleCatalog(id);
    final snapshot = await t.runAsync(() => service.request());
    service.dispose();
    final linked = {
      for (final s in snapshot!.rules.values)
        if (s.affects.isNotEmpty) s.id: s.affects.length,
    };
    expect(linked, isNotEmpty, reason: '样书含【请收藏本站】与七言，应有真实联动');
    for (final e in linked.entries) {
      final catalogRow = find.byKey(ValueKey(('rule-row', e.key)));
      final title = switch (e.key.split('.').first) {
        'cleanup' => '文本清理',
        'chapter' => '章节识别',
        _ => '排版识别',
      };
      await openTab(t, title);
      if (catalogRow.evaluate().isEmpty) continue; // 细分项的联动在展开后显示
      expect(
        find.byWidgetPredicate((w) {
          final k = w.key;
          return k is ValueKey &&
              k.value is (String, String, Object?) &&
              (k.value as (String, String, Object?)).$1 == 'rule-affects' &&
              (k.value as (String, String, Object?)).$2 == e.key;
        }),
        findsNWidgets(e.value),
      );
    }
    expect(t.takeException(), isNull);
  });

  testWidgets('新书默认：只影响以后导入的书，本书不变', (t) async {
    final (state, library, id) = await setup(t, 'v66-global-');
    await t.pumpWidget(page(library, id));
    await until(t, () => canToggle(t, 'cleanup.trim_trailing_spaces'), '开关状态');
    await t.tap(
      find.descendant(
        of: find.byKey(const ValueKey('rules-scope')),
        matching: find.text('新书默认'),
      ),
    );
    await t.pump();
    await openTab(t, '排版识别');
    await until(t, () => canToggle(t, 'layout.system'), '新书默认开关状态');
    expect(
      t
          .widget<RuleSwitch>(
            find.byKey(const ValueKey(('rule-switch', 'layout.system'))),
          )
          .on,
      true,
    );
    await t.tap(toggle('layout.system'));
    await t.pump();
    expect(find.text('1 项改动待应用 · 新书默认'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('rules-preview')));
    final apply = find.byKey(const ValueKey('rule-preview-apply'));
    await until(t, () => apply.evaluate().isNotEmpty, '预览对话框');
    expect(find.text('新书默认：只影响以后导入的书'), findsOneWidget);
    await t.tap(apply);
    await until(
      t,
      () =>
          find.textContaining('为新书默认').evaluate().isNotEmpty &&
          canToggle(t, 'layout.system'),
      '保存新书默认',
    );

    // 回到“本书”：本书的系统提示仍开启；之后导入的新书关闭。
    await t.tap(
      find.descendant(
        of: find.byKey(const ValueKey('rules-scope')),
        matching: find.text('本书'),
      ),
    );
    await t.pump();
    await until(t, () => canToggle(t, 'layout.system'), '本书开关状态');
    expect(
      t
          .widget<RuleSwitch>(
            find.byKey(const ValueKey(('rule-switch', 'layout.system'))),
          )
          .on,
      true,
    );
    expect(state.production.settings(id)['system_block_style'], isNot('off'));
    await t.runAsync(() async {
      final next = File('$root/新书.txt')
        ..writeAsStringSync('第一章 甲\n【系统】\n正文。\n');
      expect((await library.importFiles([next.path])).single.succeeded, true);
      expect(
        state.production.settings(state.currentId)['system_block_style'],
        'off',
      );
    });
    expect(t.takeException(), isNull);
  });
}
