import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';

/// V60 界面截图：排版页四个分页。输出 artifacts/v60-preview/。
void main() {
  testWidgets('截图：排版页分页', (t) async {
    final capture = GlobalKey();
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      await loadDeskFonts();
      for (final font in {
        'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(font.key)..addFont(
              File(font.value).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
      }
      final out = Directory('../artifacts/v60-preview')
        ..createSync(recursive: true);
      final root = (await out.createTemp('data-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港.txt')
        ..writeAsStringSync(
          '第一章 雾起\n港口的雾从傍晚开始往岸上爬。\n＊＊＊\n【叮！新手礼包已发放。】\n第二章 旧码头\n天亮了。\n',
        );
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    t.view.physicalSize = const Size(1100, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: deskTheme(),
          home: Scaffold(
            body: LayoutPage(
              library: library,
              bookId: id,
              navigation: LayoutNavigationGuard(),
              pickPresetFile: () async => null,
              pickPresetDestination: () async => null,
              importCss: () async => null,
              pickImage: () async => null,
            ),
          ),
        ),
      ),
    );
    Future<void> settle([int n = 20]) async {
      for (var i = 0; i < n; i++) {
        await t.pump(const Duration(milliseconds: 40));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
    }

    Future<void> shoot(String name) => t.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('../artifacts/v60-preview/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });

    final tabs = find.byKey(const ValueKey('layout-tabs'));
    for (var i = 0; i < 300 && tabs.evaluate().isEmpty; i++) {
      await settle(1);
    }
    await settle();
    await shoot('tab-text');
    for (final (label, name) in [
      ('标题', 'tab-heading'),
      ('段落与识别', 'tab-blocks'),
      ('页面与结构', 'tab-page'),
    ]) {
      await t.tap(find.descendant(of: tabs, matching: find.text(label)));
      await settle(10);
      if (name == 'tab-blocks') {
        await t.tap(
          find.byKey(const ValueKey('layout-row-system_block_style')),
        );
        await settle(5);
      }
      await shoot(name);
    }
    expect(t.takeException(), isNull);
  });
}
