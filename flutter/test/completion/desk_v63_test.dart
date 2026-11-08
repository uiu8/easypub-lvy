import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/rule_catalog_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/rules/rules_page.dart';
import 'package:easypub_desktop/desk/widgets.dart';

/// V63：识别与检查规则中心（CH-278，R2），真实 DLL。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('五组规则、本书命中与位置跳转、去设置；关掉系统提示后显示“如果开启”', (t) async {
    t.view.physicalSize = const Size(1280, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    late List<RuleDescriptor> catalog;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v63-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港.txt')
        ..writeAsStringSync(
          '第一章 雾起\n　　港口的雾从傍晚开始往岸上爬。\n【叮！新手礼包已发放。】\n'
          '＊＊＊\n　　老周把船缆绕在桩上。\n第二章 旧码头\n　　天亮了。\n',
        );
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
      final service = library.openRuleCatalog(id);
      catalog = await service.catalog();
      service.dispose();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final system = catalog.firstWhere(
      (r) =>
          r.group == 'layout' && r.parent == null && r.label.contains('系统提示'),
    );
    final opened = <RuleLocation>[];
    final settings = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: RulesPage(
            library: library,
            bookId: id,
            onOpenLocation: opened.add,
            onOpenSettings: settings.add,
          ),
        ),
      ),
    );
    Future<void> until(bool Function() ready, String what) async {
      for (var i = 0; i < 600; i++) {
        await t.pump(const Duration(milliseconds: 20));
        if (ready()) return;
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      fail('未就绪：$what');
    }

    String status() => t
        .widget<DeskTag>(
          find.descendant(
            of: find.byKey(const ValueKey('rules-status')),
            matching: find.byType(DeskTag),
          ),
        )
        .text;
    await until(() => status().startsWith('已统计'), '统计完成');
    // V64 起规则按页签分组：逐个页签确认四个自动组都在。
    for (final title in ['文本清理', '章节识别', '章节检查', '排版识别']) {
      final i = ruleGroups.indexWhere((g) => g.$3 == title);
      await t.tap(find.byKey(ValueKey('rules-tab-$i')));
      await t.pump();
      expect(find.byKey(ValueKey(('rule-group', title))), findsOneWidget);
    }
    final row = find.byKey(ValueKey(('rule-row', system.id)));
    await t.ensureVisible(row);
    await t.pump();
    expect(
      find.descendant(of: row, matching: find.text('1 处')),
      findsOneWidget,
      reason: '默认开启，本书一处系统提示',
    );
    await t.tap(row);
    await t.pump();
    final chip = find.byKey(ValueKey(('rule-location', system.id, 0)));
    await t.ensureVisible(chip);
    await t.pump();
    await t.tap(chip);
    expect(opened.single.firstLine, 2);
    expect(opened.single.sourceLine, 3);
    await t.tap(find.byKey(ValueKey(('rule-settings', system.id))));
    expect(settings.single, 'layout');

    // 关掉系统提示：书稿配置变了，自动重新统计，显示“如果开启会命中”。
    await t.runAsync(() async {
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {
              'op': 'patch',
              'fields': {
                'system_block_style': {'op': 'set', 'value': 'off'},
              },
            },
          }),
        ),
        true,
      );
    });
    // 这里紧接在统计完成之后改设置，正好落在服务释放任务句柄的窗口内；
    // 修正前状态会一直停在“取消中”。
    await until(
      () => find
          .descendant(of: row, matching: find.text('开启会命中 1 处'))
          .evaluate()
          .isNotEmpty,
      '关闭后重新统计',
    );
    expect(status(), startsWith('已统计'));
    expect(t.takeException(), isNull);
  });
}
