import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
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

class _RealHttp extends HttpOverrides {}

const ornamentPng =
    'iVBORw0KGgoAAAANSUhEUgAAAHgAAAAoCAIAAAC6iKlyAAAAcklEQVR4nO3QQREAMAjAMOTgX+FchMcaBb3OhpjrgF80Gmk00mik0UijkUYjjUYajTQaaTTSaKTRSKORRiONRhqNNBppNNJopNFIo5FGI41GGo00Gmk00mik0UijkUYjjUYajTQaaTTSaKTRSKORRq/xAMdpynmBG6HUAAAAAElFTkSuQmCC';

/// V61：真机预览适配新排版（LAY-127）——组件有全部排版项的控件，状态带“是否设了章首图”，
/// 生成内容含章首图、弹出注释与前后附页，目录里列出附页。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('组件为写回的每个排版字段都提供控件', () {
    final script = File('../plugins/kindle-preview/preview.js')
        .readAsStringSync();
    final page = File('../plugins/kindle-preview/index.html')
        .readAsStringSync();
    final keys = RegExp(r"const BOOK_KEYS = \[([^\]]*)\]")
        .firstMatch(script)!
        .group(1)!;
    final fields = RegExp(r"'([a-z_]+)'")
        .allMatches(keys)
        .map((m) => m.group(1)!)
        .toList();
    expect(fields, containsAll(['note_style', 'chapter_head_scope']));
    for (final field in fields) {
      expect(page, contains('data-key="$field"'), reason: field);
    }
  });

  testWidgets('真机预览：章首图、弹出注释与前后附页进入生成内容', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v61-'))
          .absolute
          .path;
      final ornament = '$root/花饰.png';
      File(ornament).writeAsBytesSync(base64Decode(ornamentPng));
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港来信.txt')
        ..writeAsStringSync(
          '第一章 雾港\n　　港口的雾①从傍晚开始往岸上爬。\n①雾：近地面的小水滴。\n'
          '第二章 旧码头\n　　天亮了。\n',
        );
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {
              'op': 'patch',
              'fields': {
                'note_style': {'op': 'set', 'value': 'popup'},
                'chapter_head_image': {'op': 'set', 'value': ornament},
              },
            },
          }),
        ),
        true,
      );
      final pages = library.openSupplementalPages(id);
      await pages.confirm(
        await pages.previewAdd(
          SupplementalPageContent(
            kind: SupplementalPageKind.afterword,
            title: '写在雾散之后',
            body: '谢谢读到这里的你。',
            includeToc: true,
          ),
        ),
      );
      pages.dispose();
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
    for (var i = 0; i < 100 && host.launched.isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
    final url = host.launched.single;
    final client = HttpOverrides.runWithHttpOverrides(
      HttpClient.new,
      _RealHttp(),
    );
    addTearDown(() => client.close(force: true));
    Future<String> get(Uri uri) async {
      final response = await (await client.getUrl(uri)).close();
      expect(response.statusCode, 200, reason: '$uri');
      return utf8.decodeStream(response);
    }

    Future<Map<String, dynamic>> post(String name, Object body) async {
      final request = await client.postUrl(url.resolve('api/$name'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      return jsonDecode(await utf8.decodeStream(response))
          as Map<String, dynamic>;
    }

    Future<void> network(Future<void> Function() action) async {
      var finished = false;
      Object? failure;
      StackTrace? trace;
      await t.runAsync(() async {
        unawaited(() async {
          try {
            await action();
          } catch (error, stack) {
            failure = error;
            trace = stack;
          } finally {
            finished = true;
          }
        }());
      });
      for (var i = 0; i < 3000 && !finished; i++) {
        await t.pump(const Duration(milliseconds: 10));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      if (!finished) fail('本机连接没有在时限内处理完请求');
      if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    }

    await network(() async {
      final stateJson = jsonDecode(await get(url.resolve('api/state'))) as Map;
      expect(stateJson['chapter_head'], true);
      expect(stateJson['values']['note_style'], 'popup');
      final page = await get(url);
      expect(page, contains('id="note-pop"'));
      expect(page, contains('data-key="system_block_style"'));
      final r = await post('render', {
        'values': {'system_block_style': 'indent'},
      });
      expect(r['ok'], true, reason: '${r['message']}');
      final base = '${r['base']}';
      final body = await get(url.resolve('${base}body.xhtml'));
      expect(body, contains('chapter-head-image'));
      expect(body, contains('epub:type="noteref"'));
      expect(body, contains('epub:type="footnote"'));
      final opf = await get(url.resolve('${base}package.opf'));
      final matter = RegExp(r'href="(matter-[0-9a-f]+\.xhtml)"')
          .firstMatch(opf)!
          .group(1)!;
      expect(await get(url.resolve('$base$matter')), contains('写在雾散之后'));
      // 组件只读 nav 中 epub:type="toc" 的目录；附页在其中以整个文件链接。
      final nav = await get(url.resolve('${base}nav.xhtml'));
      expect(nav, contains('href="$matter"'));
    });
    expect(t.takeException(), isNull);
  });
}
