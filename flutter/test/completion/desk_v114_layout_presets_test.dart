import 'dart:io';

import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/layout_presets_dialog.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// V114：内置排版预设——出厂默认之外有四套可选；内置预设直接预览并应用，
/// “出版社纸书”一并套用“素雅”样式包；出厂默认不变。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('内置预设：四套可选，应用“出版社纸书”时带上素雅样式包', (t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late LayoutSession session;
    late List<LayoutPreset> builtins;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v114-presets-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')
        ..writeAsStringSync('第一章 开始\n　　正文一。\n第二章 继续\n　　正文二。\n');
      await library.importFiles([file.path]);
      session = library.openLayout(state.currentId);
      builtins = await session.builtinPresets();
    });
    addTearDown(() {
      session.dispose();
      library.dispose();
      state.dispose();
    });
    expect(builtins.map((p) => p.name), [
      '出厂默认',
      '出版社纸书',
      '网文舒适',
      '古籍竖排',
      '简洁章首',
    ]);
    // 出厂默认不变：书导入后仍是出厂排版。
    expect(builtins[0].values['font_family'], 'Microsoft YaHei');
    expect(session.saved['heading_style'], 'classic');
    expect(builtins[3].values['writing_mode'], 'vertical');
    expect(builtins[1].stylePack, 'plain');

    // 并发跑全量时后端较慢：最多等 6 秒，条件满足就停。
    Future<void> settle([bool Function()? done]) async {
      for (var i = 0; i < 300; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump();
        if (i >= 10 && (done == null || done())) return;
      }
    }

    bool? applied;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => applied = await showDialog<bool>(
                context: context,
                builder: (_) => LayoutPresetsDialog(
                  session: session,
                  values: session.saved,
                  allowApply: true,
                  label: (key) => key,
                  valueText: (_, value) => '$value',
                  pickFile: () async => null,
                  pickDestination: () async => null,
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开'));
    await settle();
    await t.tap(find.text('内置'));
    await settle();
    expect(find.textContaining('配“素雅”样式包'), findsOneWidget);
    await t.tap(find.text('出版社纸书'));
    await t.pump();
    await t.tap(find.text('预览并确认'));
    await settle(() => find.text('应用排版预设').evaluate().isNotEmpty);
    expect(find.text('应用排版预设'), findsOneWidget);
    await t.tap(find.text('确认应用'));
    await settle(() => applied != null);
    expect(applied, isTrue);
    expect(session.saved['heading_style'], 'publisher');
    expect(state.production.settings(state.currentId)['font_family'], 'SimSun');
    expect(session.saved['line_height'], 1.65);
    final style = session.saved['chapter_style'] as Map?;
    expect(style?['name'], '素雅');
    expect((style?['head_images'] as List?)?.isNotEmpty, isTrue);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
