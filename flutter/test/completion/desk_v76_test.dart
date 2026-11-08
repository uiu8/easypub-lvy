import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
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

/// V76：真机预览适配生僻字注音与章节样式包（LAY-131）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('真机预览：注音与样式包进入生成内容，侧边栏可调并写回', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v76-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/龘山.txt')
        ..writeAsStringSync('第一章 远行\n城外有座龘山。\n第二章 归来\n再回到龘山。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
      final built = await state.production.productionRequest(
        jsonEncode({
          'op': 'chapter_style',
          'action': 'builtin',
          'id': 'classic',
          'dir': '$root/packs',
        }),
      );
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {
              'op': 'patch',
              'fields': {
                'chapter_style': {'op': 'set', 'value': built['style']},
              },
            },
          }),
        ),
        true,
      );
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
    Future<(int, String)> fetch(Uri uri) async {
      final response = await (await client.getUrl(uri)).close();
      return (response.statusCode, await utf8.decodeStream(response));
    }

    Future<String> get(Uri uri) async {
      final (code, body) = await fetch(uri);
      expect(code, 200, reason: '$uri');
      return body;
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

    // 生成一次，返回正文与样式表。
    Future<(String, String, String)> render(Map<String, Object?> values) async {
      final r = await post('render', {'values': values});
      expect(r['ok'], true, reason: '${r['message']}');
      final base = '${r['base']}';
      final opf = await get(url.resolve('${base}package.opf'));
      final css = RegExp(r'href="([^"]+\.css)"')
          .allMatches(opf)
          .map((m) => m.group(1)!)
          .toList();
      final styles = [for (final c in css) await get(url.resolve('$base$c'))]
          .join('\n');
      final body = [
        for (final m in RegExp(
          r'href="([^"]+\.xhtml)"',
        ).allMatches(opf).map((m) => m.group(1)!))
          if (!m.startsWith('nav') && !m.startsWith('toc'))
            await get(url.resolve('$base$m')),
      ].join('\n');
      return (base, body, styles);
    }

    await network(() async {
      final stateJson = jsonDecode(await get(url.resolve('api/state'))) as Map;
      // 只用样式包、没设章首图时，也显示章首图的范围与宽度。
      expect(stateJson['chapter_head'], true);
      expect(stateJson['chapter_style_name'], '古典');
      final values = stateJson['values'] as Map;
      expect(values['chapter_style_on'], 'on');
      expect(values['chapter_style_volume_frame'], 'double');
      expect(values['rare_char_ruby'], 'chapter');
      final page = await get(url);
      for (final key in [
        'rare_char_ruby',
        'rare_char_scope',
        'chapter_style_on',
        'chapter_style_volume_frame',
      ]) {
        expect(page, contains('data-key="$key"'));
      }
      expect(page, contains('id="chapter-style-name"'));

      // 当前设置：注音、章头图、装饰线、章末装饰、双线卷框；图片能取到。
      final (base, body, css) = await render({});
      expect(body, contains('<rt>dá</rt>'));
      expect(body, contains('chapter-head-image'));
      expect(body, contains('class="title-rule"'));
      expect(body, contains('class="chapter-end"'));
      expect(css, contains('.volume-heading { border: 3px double;'));
      final image = RegExp(r'class="title-rule"><img src="([^"]+)"')
          .firstMatch(body)!
          .group(1)!;
      final picture = await (await client.getUrl(url.resolve('$base$image')))
          .close();
      expect(picture.statusCode, 200);
      await picture.drain<void>();

      // 预览里改：不标注音、停用样式包。
      final (_, plain, plainCss) = await render({
        'rare_char_ruby': 'off',
        'chapter_style_on': 'off',
      });
      expect(plain, isNot(contains('<ruby>')));
      expect(plain, isNot(contains('title-rule')));
      expect(plain, isNot(contains('chapter-head-image')));
      // 新书默认开着场景样式（V81），样式表里别处也有双线，只看卷页边框。
      expect(plainCss, isNot(contains('.volume-heading { border:')));
      // 卷页边框改单线。
      final (_, _, single) = await render({
        'chapter_style_volume_frame': 'single',
      });
      expect(single, contains('.volume-heading { border: 1px solid;'));

      // 写回：卷页边框与注音方式。
      final applied = await post('apply', {
        'values': {
          'chapter_style_volume_frame': 'single',
          'rare_char_ruby': 'every',
        },
      });
      expect(applied['ok'], true, reason: '${applied['message']}');
    });
    for (var i = 0; i < 200; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      final s = state.production.settings(id);
      if ((s['chapter_style'] as Map?)?['volume_frame'] == 'single' &&
          s['rare_char_ruby'] == 'every') {
        break;
      }
    }
    final saved = state.production.settings(id);
    expect((saved['chapter_style'] as Map)['volume_frame'], 'single');
    expect(saved['rare_char_ruby'], 'every');

    // 写回“不使用”：停用样式包。
    await network(() async {
      final off = await post('apply', {
        'values': {'chapter_style_on': 'off'},
      });
      expect(off['ok'], true, reason: '${off['message']}');
    });
    expect(state.production.settings(id)['chapter_style'], isNull);
    expect(t.takeException(), isNull);
  });
}
