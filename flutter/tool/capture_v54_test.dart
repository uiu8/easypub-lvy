import 'dart:convert';
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

const ornamentPng =
    'iVBORw0KGgoAAAANSUhEUgAAAHgAAAAoCAIAAAC6iKlyAAAAcklEQVR4nO3QQREAMAjAMOTgX+FchMcaBb3OhpjrgF80Gmk00mik0UijkUYjjUYajTQaaTTSaKTRSKORRiONRhqNNBppNNJopNFIo5FGI41GGo00Gmk00mik0UijkUYjjUYajTQaaTTSaKTRSKORRq/xAMdpynmBG6HUAAAAAElFTkSuQmCC';

/// V54 界面截图：排版页“章首图”一组（已设图，显示用于与宽度）。输出 artifacts/v54-preview/。
void main() {
  testWidgets('截图：排版页章首图', (t) async {
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
      final out = Directory('../artifacts/v54-preview')
        ..createSync(recursive: true);
      final root = (await out.createTemp('data-')).absolute.path;
      final ornament = '$root/花饰.png';
      File(ornament).writeAsBytesSync(base64Decode(ornamentPng));
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港.txt')
        ..writeAsStringSync('第一章 雾起\n港口的雾从傍晚开始往岸上爬。\n第二章 旧码头\n天亮了。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
      final change = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'chapter_head_image': {'op': 'set', 'value': ornament},
          },
        },
      });
      expect(await state.production.confirm(change), true);
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
    final tabs = find.byKey(const ValueKey('layout-tabs'));
    for (var i = 0; i < 300 && tabs.evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    await t.tap(find.descendant(of: tabs, matching: find.text('标题')));
    await t.pump();
    final scope = find.byKey(const ValueKey('layout-chapter_head_scope'));
    for (var i = 0; i < 300 && scope.evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    await t.ensureVisible(
      find.byKey(const ValueKey('layout-chapter-head-name')),
    );
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await t.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('../artifacts/v54-preview/layout-chapter-head.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    expect(t.takeException(), isNull);
  });
}
