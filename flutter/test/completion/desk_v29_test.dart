import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/app_info.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/settings/settings_page.dart';
import 'package:easypub_desktop/desk/widgets.dart';

/// V29：设置页说明精简——分区说明去掉，组标题与开关的说明收进“?”（SET-068）。
void main() {
  testWidgets('设置页各分区不再显示说明行，说明在“?”里，点“?”不切换开关', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = (await Directory('../artifacts').createTemp('v29-settings-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: SettingsPage(
            settings: library,
            library: library,
            appInfo: () async => const AppInfo(packaged: false),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    String help(String title) => t
        .widget<DeskHelp>(find.byKey(ValueKey('settings-help-$title')))
        .message;
    Finder text(String s) => find.textContaining(s);
    Future<void> open(String tab) async {
      await t.tap(find.text(tab).first);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: tab);
    }

    // 外观与交互：分区说明与复述开关名的说明不再显示。
    expect(text('文字、密度与动画'), findsNothing);
    expect(text('启动时恢复上次窗口状态'), findsNothing);

    await open('导入与收藏');
    expect(text('调用系统文件选择器'), findsNothing);
    expect(text('收藏位置与当前书库条目独立'), findsNothing);
    expect(text('导入文件夹时包含子目录'), findsNothing);
    expect(find.text('递归扫描子文件夹'), findsOneWidget);
    expect(text('导入创建工作引用'), findsNothing);
    expect(help('默认导入位置'), contains('不会移动或覆盖原文件'));
    expect(help('章节识别'), contains('已有书籍在章节页预览重新识别'));
    // 点开关旁的“?”只显示说明，不切换开关。
    final row = find
        .ancestor(of: find.text('导入后检查章节识别结果'), matching: find.byType(InkWell))
        .first;
    final before = t
        .widget<Switch>(find.descendant(of: row, matching: find.byType(Switch)))
        .value;
    await t.tap(find.descendant(of: row, matching: find.byType(DeskHelp)));
    await t.pump(const Duration(milliseconds: 300));
    expect(
      t
          .widget<Switch>(
            find.descendant(of: row, matching: find.byType(Switch)),
          )
          .value,
      before,
    );
    expect(find.textContaining('检查不修改正文'), findsOneWidget);
    await t.pumpAndSettle(const Duration(seconds: 31));

    await open('成品与输出');
    expect(text('用于新建转换任务'), findsNothing);
    expect(text('本次转换计划中再次确认'), findsNothing);
    expect(text('输出保护'), findsNothing);
    expect(text('文件名示例'), findsOneWidget);

    await open('自动检查');
    expect(text('检查结果不是转换门槛'), findsNothing);
    expect(text('基础检查'), findsNothing);
    expect(text('问题不等于结论'), findsNothing);
    expect(find.text('文件与输出位置 · 格式与转换器 · 元信息与资源 · 章节结构与编号'), findsOneWidget);
    expect(help('始终执行'), contains('问题不等于结论'));
    expect(help('始终执行'), contains('章节结构与编号'));

    await open('转换工具');
    expect(text('管理各输出格式使用的工具'), findsNothing);
    expect(text('随 EasyPub++ 一起更新'), findsNothing);
    expect(text('内置生成器'), findsNothing);
    expect(text('与 AZW3 共用 Kindling 兼容转换流程'), findsNothing);
    expect(text('实际调用'), findsNothing);
    expect(find.text('与 AZW3 共用工具'), findsOneWidget);

    await open('数据与迁移');
    expect(text('备份和恢复软件设置'), findsNothing);
    expect(text('每本书保留当前稿和上一稿'), findsNothing);
    expect(help('检查缓存'), contains('每本书保留当前稿和上一稿'));

    await open('关于与许可');
    expect(text('的组件、转换器和许可信息'), findsNothing);
    expect(find.text('Rust + Flutter'), findsNothing);
    expect(find.text('设置的来源与优先级'), findsOneWidget);
    expect(help('设置的来源与优先级'), contains('后面的覆盖前面的'));
  });
}
