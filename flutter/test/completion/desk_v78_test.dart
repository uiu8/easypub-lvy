import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';

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

/// V78：系统提示样式编辑器、我的样式、样式包带块样式（LAY-133）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('编辑器调参数并另存为我的样式；我的样式可选可删；样式包带块样式', (t) async {
    t.view.physicalSize = const Size(1280, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id, root;
    await t.runAsync(() async {
      for (final entry in {
        'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(entry.key)..addFont(
              File(entry.value)
                  .readAsBytes()
                  .then((b) => b.buffer.asByteData()),
            ))
            .load();
      }
      root = (await Directory('../artifacts').createTemp('v78-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/系统流.txt')
        ..writeAsStringSync('第一章 开始\n【苍白的正义】\n【攻击力：20-25】\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final capture = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: LayoutPage(
              library: library,
              bookId: id,
              navigation: LayoutNavigationGuard(),
              pickPresetFile: () async => null,
              pickPresetDestination: () async => null,
              importCss: () async => null,
              pickStylePack: () async => null,
              pickStylePackDestination: (_) async => null,
            ),
          ),
        ),
      ),
    );
    Future<void> shoot(String name) => t.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final dir = Directory('../artifacts/v78-preview')
        ..createSync(recursive: true);
      await File('${dir.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    Map? styles() => state.production.settings(id)['system_styles'] as Map?;
    List saved() =>
        (library.snapshot.value.configuration['block_style_library']
            as List?) ??
        const [];

    final tabs = find.byKey(const ValueKey('layout-tabs'));
    await until(t, () => tabs.evaluate().isNotEmpty);
    await t.tap(find.descendant(of: tabs, matching: find.text('段落与识别')));
    await t.pump();
    final row = find.byKey(const ValueKey('layout-row-system_block_style'));
    await t.ensureVisible(row);
    await t.tap(row);
    await t.pump();
    final edit = find.byKey(const ValueKey('layout-system-edit-panel'));
    await until(t, () => edit.evaluate().isNotEmpty);
    await t.ensureVisible(edit);
    await t.pump();
    await t.tap(edit);
    await until(
      t,
      () => find
          .byKey(const ValueKey('block-editor-border'))
          .evaluate()
          .isNotEmpty,
    );
    // 改成上下双线、标题下划线，另存为“装备卡”。
    await t.tap(
      find.descendant(
        of: find.byKey(const ValueKey('block-editor-border')),
        matching: find.text('上下'),
      ),
    );
    await t.tap(
      find.descendant(
        of: find.byKey(const ValueKey('block-editor-title')),
        matching: find.text('下划线'),
      ),
    );
    await t.enterText(find.byKey(const ValueKey('block-editor-name')), '装备卡');
    await t.pump();
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    await shoot('block-style-editor');
    await t.tap(find.byKey(const ValueKey('block-editor-apply')));
    await until(
      t,
      () =>
          (styles()?['panel'] as Map?)?['title'] == 'underline' &&
          saved().isNotEmpty,
    );
    final panel = Map<String, Object>.from(styles()!['panel'] as Map);
    expect(panel['border'], 'top_bottom');
    expect(panel['key_bold'], true, reason: '其余参数沿用标题面板');
    expect(saved().single, {'name': '装备卡', 'kind': 'panel', 'style': panel});
    expect(describeSystemStyles(styles()), '单行提示条 · 面板自定义');
    // 我的样式出现在选项里且被选中；选回内置再选“装备卡”。
    final mine = find.byKey(
      const ValueKey(('layout-system-saved', 'panel', '装备卡')),
    );
    await until(t, () => mine.evaluate().isNotEmpty);
    expect(t.widget<InputChip>(mine).selected, true);
    await t.tap(find.byKey(const ValueKey('layout-system-panel-rules')));
    await until(t, () => (styles()?['panel'] as Map?)?['line'] == 'double');
    expect(t.widget<InputChip>(mine).selected, false);
    await t.tap(mine);
    await until(t, () => (styles()?['panel'] as Map?)?['title'] == 'underline');
    await shoot('system-styles-row');
    // 删除我的样式：本书参数不变。
    await t.tap(
      find.descendant(of: mine, matching: find.byTooltip('从我的样式中删除')).first,
    );
    await until(t, () => saved().isEmpty);
    expect((styles()!['panel'] as Map)['title'], 'underline');

    // 样式包：选“古典”后一并套用居中强调与上下双线。
    await t.tap(find.descendant(of: tabs, matching: find.text('标题')).first);
    await t.pump();
    final classic = find.byKey(const ValueKey('layout-chapter-style-classic'));
    await until(t, () => classic.evaluate().isNotEmpty);
    await t.ensureVisible(classic);
    await t.pump();
    await t.tap(classic);
    await until(t, () => (styles()?['note'] as Map?)?['align'] == 'center');
    expect(styles()!['panel'], blockStylePresets['rules']);
    expect(state.production.settings(id)['system_block_style'], 'styled');
    expect(t.takeException(), isNull);
  });

  test('样式包导出带块样式，导入后取回；我的样式非法时保存被拒', () async {
    final root = (await Directory('../artifacts').createTemp('v78-pack-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      final built = await state.production.productionRequest(
        jsonEncode({
          'op': 'chapter_style',
          'action': 'builtin',
          'id': 'plain',
          'dir': '$root/packs',
        }),
      );
      expect(built['blocks'], defaultSystemStyles());
      final blocks = {
        'note': blockStylePresets['center'],
        'panel': blockStylePresets['rules'],
      };
      await state.production.productionRequest(
        jsonEncode({
          'op': 'chapter_style',
          'action': 'export',
          'style': built['style'],
          'blocks': blocks,
          'path': '$root/我的.zip',
        }),
      );
      final imported = await state.production.productionRequest(
        jsonEncode({
          'op': 'chapter_style',
          'action': 'import',
          'path': '$root/我的.zip',
          'dir': '$root/installed',
        }),
      );
      expect(imported['blocks'], blocks);
      expect(
        await library.savePatch({
          'block_style_library': [
            {
              'name': '坏',
              'kind': 'note',
              'style': {...blockStylePresets['bar']!, 'title': 'shaded'},
            },
          ],
        }),
        false,
      );
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
