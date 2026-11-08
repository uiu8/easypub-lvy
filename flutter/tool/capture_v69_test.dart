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

/// V69 截图：书籍标签页、主题色（青 / 默认墨灰）、设置页色块。输出 artifacts/v69-preview/。
void main() {
  testWidgets('截图：主题色与书籍标签页', (t) async {
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
    late String a, b;
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
      final out = Directory('../artifacts/v69-preview')
        ..createSync(recursive: true);
      final tmp = (await out.createTemp('data-')).absolute;
      state = PrototypeState(settingsDirectory: '${tmp.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({
        'check_after_import': false,
        'ui_accent': 'teal',
      });
      for (final name in ['龙游令', '雾港来信', '夜读']) {
        final f = File(
          '${tmp.path}/$name.txt',
        )..writeAsStringSync('第一章 远行\n山路很长。\n第二章 归来\n海风很轻。\n第四章 远航\n船离开了码头。\n');
        expect((await library.importFiles([f.path])).single.succeeded, true);
      }
      final books = library.books.value;
      a = books.firstWhere((x) => x.title == '龙游令').id;
      b = books.firstWhere((x) => x.title == '雾港来信').id;
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
      await File('../artifacts/v69-preview/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });

    await t.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: RewriteApp(
          library: library,
          picker: NoPicker(),
          initialLocation: '/books/${Uri.encodeComponent(b)}/information',
        ),
      ),
    );
    await settle();
    GoRouter router() => GoRouter.of(t.element(find.byType(Scaffold).first));
    router().go('/books/${Uri.encodeComponent(a)}/checks');
    await settle(120);
    await shoot('tabs-teal');
    router().go('/settings');
    await settle();
    await shoot('settings-accent');
    await t.tap(find.byKey(const ValueKey('settings-accent-ink')));
    await settle();
    router().go('/books/${Uri.encodeComponent(a)}/checks');
    await settle(120);
    await shoot('tabs-ink');
    expect(t.takeException(), isNull);
    library.dispose();
    state.dispose();
    debugDisableShadows = true;
  });
}
