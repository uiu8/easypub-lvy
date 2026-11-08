import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:go_router/go_router.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:easypub_desktop/desk/grain.dart';

class NoPicker extends Fake implements BookFilePicker {}

/// V79 截图：宣纸 / 夜墨 / 高对比下的主要页面。输出 artifacts/v79-preview/。
void main() {
  testWidgets('截图：三种主题的主要页面', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    debugDisableShadows = false;
    t.view.physicalSize = const Size(1440, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final capture = GlobalKey();
    late LegacyLibraryAdapter library;
    late PrototypeState state;
    late String a;
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
      await prepareDeskGrain();
      final out = Directory('../artifacts/v79-preview')
        ..createSync(recursive: true);
      final tmp = (await out.createTemp('data-')).absolute;
      state = PrototypeState(settingsDirectory: '${tmp.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      for (final name in ['龙游令', '雾港来信', '夜读']) {
        final f = File('${tmp.path}/$name.txt')
          ..writeAsStringSync(
            '第一章 远行\n山路很长。\n【叮！获得经验+120】\n第二章 归来\n【苍白的正义】\n【攻击力：20-25】\n海风很轻。\n第四章 远航\n船离开了码头。\n',
          );
        expect((await library.importFiles([f.path])).single.succeeded, true);
      }
      a = library.books.value.firstWhere((x) => x.title == '龙游令').id;
    });
    Future<void> settle([int n = 60]) async {
      for (var i = 0; i < n; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> shoot(String name) => t.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('../artifacts/v79-preview/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });

    await t.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: RewriteApp(
          library: library,
          picker: NoPicker(),
          initialLocation: '/',
        ),
      ),
    );
    await settle();
    GoRouter router() => GoRouter.of(t.element(find.byType(Scaffold).first));
    final pages = {
      'library': '/',
      'chapters': '/books/${Uri.encodeComponent(a)}/chapters',
      'checks': '/books/${Uri.encodeComponent(a)}/checks',
      'layout': '/books/${Uri.encodeComponent(a)}/layout',
      'conversion': '/conversion',
      'settings': '/settings',
    };
    for (final mode in ['night', 'contrast', 'paper']) {
      await t.runAsync(() => library.savePatch({'ui_theme': mode}));
      await settle();
      for (final e in pages.entries) {
        router().go(e.value);
        await settle(100);
        await shoot('$mode-${e.key}');
      }
    }
    expect(t.takeException(), isNull);
    library.dispose();
    state.dispose();
    debugDisableShadows = true;
  });
}
