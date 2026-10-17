import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/manual_note_service.dart';
import 'package:easypub_desktop/application/supplemental_page_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/kindle_preview_launcher.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';

class _Host implements KindlePreviewHost {
  final launched = <Uri>[];
  @override
  String? findEdge() => 'msedge.exe';
  @override
  String? findPlugin() => Directory('../plugins/kindle-preview').absolute.path;
  @override
  Future<void> launch(String edge, Uri url) async => launched.add(url);
}

/// 120×40 深灰横条（花饰）与 90×160 蓝色竖图（整页插图）。
const ornamentPng =
    'iVBORw0KGgoAAAANSUhEUgAAAHgAAAAoCAIAAAC6iKlyAAAAcklEQVR4nO3QQREAMAjAMOTgX+FchMcaBb3OhpjrgF80Gmk00mik0UijkUYjjUYajTQaaTTSaKTRSKORRiONRhqNNBppNNJopNFIo5FGI41GGo00Gmk00mik0UijkUYjjUYajTQaaTTSaKTRSKORRq/xAMdpynmBG6HUAAAAAElFTkSuQmCC';
const pagePng =
    'iVBORw0KGgoAAAANSUhEUgAAAFoAAACgCAIAAAADw+wqAAAA6ElEQVR4nO3QMQ0AIADAMJSgBNkI5EMC42gyAUvHXFu3kR98FQ4cOHDgwIEDBw4cfThw4MCBAwcOHDhw9OHAgQMHDhw4cODA0YcDBw4cOHDgwIEDRx8OHDhw4MCBAwcOHH04cODAgQMHDhw4cPThwIEDBw4cOHDgwNGHAwcOHDhw4MCBA0cfDhw4cODAgQMHDhx9OHDgwIEDBw4cOHD04cCBAwcOHDhw4MDRhwMHDhw4cODAgQNHHw4cOHDgwIEDBw4cfThw4MCBAwcOHDhw9OHAgQMHDhw4cODA0YcDBw4cOHDgwLEecRyN+1b2vJkg2QAAAABJRU5ErkJggg==';

/// V61：生成含全部新功能的样书，启动真实的真机预览服务，把地址写到 artifacts/v61-preview/url.txt，
/// 供浏览器手动检查；同目录出现 stop 文件或 15 分钟后结束。
void main() {
  testWidgets('真机预览服务（手动检查用）', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    final out = Directory('../artifacts/v61-preview')
      ..createSync(recursive: true);
    final stop = File('${out.path}/stop');
    if (stop.existsSync()) stop.deleteSync();
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = (await out.createTemp('data-')).absolute.path;
      final ornament = '$root/花饰.png', page = '$root/整页.png';
      File(ornament).writeAsBytesSync(base64Decode(ornamentPng));
      File(page).writeAsBytesSync(base64Decode(pagePng));
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港来信.txt')
        ..writeAsStringSync(
          '第一章 雾港\n'
          '　　港口的雾（甲）从傍晚开始往岸上爬①，先吞掉了灯塔的底座。\n'
          '①雾：近地面空气中的水汽凝结成的小水滴。\n'
          '作者注：这里的雾指海雾，春夏之交最常见。\n'
          '　　老周把船缆绕在桩上，抬头看了一眼天色。\n'
          '＊＊＊\n'
          '【叮！新手礼包已发放。】\n'
          '床前明月光，疑是地上霜。\n'
          '举头望明月，低头思故乡。\n'
          '——李白《静夜思》\n'
          '第二章 旧码头\n'
          '　　旧码头在晨光里显出轮廓，木桩上长满了青苔。\n'
          '　　船夫收起缆绳，沿着木桥走向岸边。\n'
          '　　天亮了。\n',
        );
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {
              'op': 'patch',
              'fields': {
                'author': {'op': 'set', 'value': '林舟'},
                'note_style': {'op': 'set', 'value': 'popup'},
                'chapter_head_image': {'op': 'set', 'value': ornament},
                'chapter_head_width': {'op': 'set', 'value': 'third'},
                'first_paragraph_style': {
                  'op': 'set',
                  'value': 'large_initial',
                },
              },
            },
          }),
        ),
        true,
      );
      final resources = library.openResources(id);
      await resources.apply(
        await resources.change(
          index: null,
          path: page,
          caption: '整页插图：旧码头',
          alt: '旧码头',
          sourceLine: 13,
          layout: 'full_page',
        ),
      );
      resources.dispose();
      final pages = library.openSupplementalPages(id);
      for (final content in [
        SupplementalPageContent(
          kind: SupplementalPageKind.copyright,
          title: '版权信息',
          body: '书名：雾港来信\n作者：林舟\n© 2026 保留所有权利',
          includeToc: true,
        ),
        SupplementalPageContent(
          kind: SupplementalPageKind.afterword,
          title: '写在雾散之后',
          body: '写完最后一章的那天，港口的雾终于散了。\n\n谢谢读到这里的你。',
          includeToc: true,
        ),
      ]) {
        await pages.confirm(await pages.previewAdd(content));
      }
      pages.dispose();
      final notes = library.openManualNotes(id);
      final tree = await library.openChapters(id).read(0);
      var snapshot = await notes.list();
      const line = '　　港口的雾（甲）从傍晚开始往岸上爬①，先吞掉了灯塔的底座。';
      final reference = await notes.resolvePosition(
        snapshot,
        entryId: tree.nodes.first.id,
        line: 1,
        utf16Start: line.indexOf('（甲）'),
        utf16End: line.indexOf('（甲）') + 3,
      );
      final definition = await notes.resolvePosition(
        snapshot,
        entryId: tree.nodes.first.id,
        line: 3,
        utf16Start: 0,
        utf16End: 0,
      );
      await notes.confirm(
        await notes.previewAdd(
          snapshot,
          ManualNoteDraft.pair(reference, definition),
        ),
      );
      snapshot = await notes.list();
      final position = await notes.resolvePosition(
        snapshot,
        entryId: tree.nodes.last.id,
        line: 1,
        utf16Start: 5,
        utf16End: 5,
      );
      await notes.confirm(
        await notes.previewAdd(
          snapshot,
          ManualNoteDraft.newText(position, '旧码头：清末修建，后来废弃。\n第二段：新写注释可以分段。'),
        ),
      );
      notes.dispose();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final host = _Host();
    await t.pumpWidget(
      MaterialApp(
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
            kindlePreview: host,
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('layout-kindle-preview'));
    for (var i = 0; i < 600 && button.evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    await t.tap(button);
    for (var i = 0; i < 200 && host.launched.isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
    final url = host.launched.single;
    await t.runAsync(
      () => File('${out.path}/url.txt').writeAsString(url.toString()),
    );
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    while (DateTime.now().isBefore(deadline) && !stop.existsSync()) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(t.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
