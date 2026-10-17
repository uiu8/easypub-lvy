import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:easypub_desktop/desk/grain.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class NoPicker extends Fake implements BookFilePicker {}

/// V1 编辑台外壳：四种窗口尺寸下标题栏、导航栏、托盘不溢出；导航栏按宽度展开；
/// Ctrl+K 打开命令面板，拼音首字母可检索，选择后只跳转页面。
/// 设置 DESK_SHELL_CAPTURE=<目录> 时同时输出截图。
void main() {
  const sizes = [
    Size(1024, 700),
    Size(1280, 800),
    Size(1440, 900),
    Size(1920, 1080),
  ];
  testWidgets('desk shell fits four window sizes and opens the palette', (
    t,
  ) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    late LegacyLibraryAdapter library;
    late String bookId;
    final capture = Platform.environment['DESK_SHELL_CAPTURE'];
    // flutter_test 默认不画阴影模糊；截图时恢复，使阴影与真实窗口一致。
    if (capture != null) {
      debugDisableShadows = false;
    }
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File(
            Platform.environment['EASYPUB_TEST_DLL'] ??
                '../target/release/easypub_bridge.dll',
          ).absolute.path,
        ),
      );
      if (capture != null) {
        await loadDeskFonts();
        await (FontLoader('MaterialIcons')..addFont(
              File(
                'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
        await prepareDeskGrain();
      }
      final tmp = await Directory.systemTemp.createTemp('easypub-desk-shell-');
      final state = PrototypeState(settingsDirectory: '${tmp.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      final file = File('${tmp.path}/山海之间.txt');
      await file.writeAsString('第一章 远行\n山路很长。\n\n第二章 归来\n海风很轻。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      bookId = library.books.value.single.id;
    });
    library.selectBook(bookId);
    Future<void> settle() async {
      for (var i = 0; i < 120; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
        if (i > 10 &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
    }

    final boundary = GlobalKey();
    for (final size in sizes) {
      t.view.physicalSize = size * 1.25;
      t.view.devicePixelRatio = 1.25;
      for (final route in [
        '/',
        '/books/${Uri.encodeComponent(bookId)}/chapters',
      ]) {
        await t.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: RewriteApp(
              key: ValueKey('$size $route'),
              library: library,
              picker: NoPicker(),
              initialLocation: route,
            ),
          ),
        );
        await settle();
        expect(t.takeException(), isNull, reason: '$size $route');
        final rail = t.getSize(find.byKey(const ValueKey('desk-rail')));
        expect(rail.width, size.width >= 1440 ? 212 : 64, reason: '$size');
        expect(find.byKey(const ValueKey('workspace-book-picker')), findsOne);
        expect(
          t.getRect(find.byKey(const ValueKey('workspace-output-bar'))).bottom,
          closeTo(size.height, .5),
        );
        if (capture != null) {
          await t.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1.25);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final name = route == '/' ? 'library' : 'chapters';
            final out = File(
              '$capture/v1_${name}_${size.width.toInt()}x${size.height.toInt()}.png',
            );
            await out.parent.create(recursive: true);
            await out.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
    }

    // 命令面板：Ctrl+K 打开，拼音首字母检索，回车跳转。
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyK);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle();
    expect(find.byKey(const ValueKey('desk-command-query')), findsOne);
    await t.enterText(find.byKey(const ValueKey('desk-command-query')), 'zhrw');
    await t.pump();
    expect(find.text('转换任务'), findsOne);
    expect(find.text('书库'), findsWidgets);
    await t.pump(const Duration(milliseconds: 400));
    if (capture != null) {
      await t.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.25);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$capture/v1_command_palette_1920x1080.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle();
    final router = GoRouter.of(
      t.element(find.byKey(const ValueKey('workspace-output-bar'))),
    );
    expect(router.routeInformationProvider.value.uri.path, '/tasks');
    expect(find.byKey(const ValueKey('desk-command-query')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    debugDisableShadows = true;
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
}
