// 拖入图片设封面与下载书的同名封面（R1 后，用户反馈）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/metadata/cover_drop.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一张 300×400 的 PNG（纯色）。
Future<void> writePng(String path) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 300, 400),
    Paint()..color = const Color(0xFF336699),
  );
  final image = await recorder.endRecording().toImage(300, 400);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
  });

  Future<(LegacyLibraryAdapter, Directory)> library(WidgetTester t) async {
    late LegacyLibraryAdapter lib;
    late Directory tmp;
    await t.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('desk-cover-drop-');
      final state = PrototypeState(settingsDirectory: '${tmp.path}/settings');
      lib = LegacyLibraryAdapter(backend: state);
      await lib.load();
      await lib.savePatch({'check_after_import': false});
    });
    return (lib, tmp);
  }

  testWidgets('下载的书加入书库时自动用同名图片作封面；已有封面不覆盖', (t) async {
    final (lib, tmp) = await library(t);
    await t.runAsync(() async {
      final txt = '${tmp.path}/下载的书.txt';
      await File(txt).writeAsString('第一章 开始\n正文。\n');
      await writePng('${tmp.path}/下载的书.png');
      expect((await lib.importFiles([txt])).single.succeeded, true);
      expect(await bindSidecarCover(lib, txt), true);
      final book = lib.books.value.single;
      expect(book.coverPath, isNotEmpty);
      // 再绑一次：已有封面，不覆盖。
      expect(await bindSidecarCover(lib, txt), false);
      // 没有同名图片的书：不处理。
      final plain = '${tmp.path}/没有封面.txt';
      await File(plain).writeAsString('第一章 开始\n正文。\n');
      await lib.importFiles([plain]);
      expect(await bindSidecarCover(lib, plain), false);
    });
  });

  testWidgets('拖入图片：弹窗预先核验这张图，确认后写入封面', (t) async {
    final (lib, tmp) = await library(t);
    late String id;
    final image = '${tmp.path}/拖入.png';
    await t.runAsync(() async {
      final txt = '${tmp.path}/书.txt';
      await File(txt).writeAsString('第一章 开始\n正文。\n');
      await writePng(image);
      await lib.importFiles([txt]);
      id = lib.books.value.single.id;
    });
    String? result;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await adoptCoverImage(context, lib, id, image),
              child: const Text('拖入'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('拖入'));
    for (var i = 0; i < 40 && find.text('使用此图片').evaluate().isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 20));
    }
    // 预先核验后，“使用此图片”可用。
    for (var i = 0; i < 40; i++) {
      final button = t.widget<DeskButton>(
        find.ancestor(
          of: find.text('使用此图片'),
          matching: find.byType(DeskButton),
        ),
      );
      if (button.onPressed != null) break;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 20));
    }
    await t.tap(find.text('使用此图片'));
    for (var i = 0; i < 60 && result == null; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(result, '已设为封面');
    expect(lib.books.value.single.coverPath, isNotEmpty);
  });

  test('只把常见图片扩展名当作封面图片', () {
    expect(isCoverImagePath(r'C:\a\b.JPG'), true);
    expect(isCoverImagePath('b.webp'), true);
    expect(isCoverImagePath('b.txt'), false);
    expect(isCoverImagePath('b'), false);
  });
}
