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
import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';

class _Host implements KindlePreviewHost {
  _Host({this.edge = 'msedge.exe'});
  final String? edge;
  final launched = <Uri>[];
  @override
  String? findEdge() => edge;
  @override
  String? findPlugin() => Directory('../plugins/kindle-preview').absolute.path;
  @override
  Future<void> launch(String edge, Uri url) async => launched.add(url);
}

class _RealHttp extends HttpOverrides {}

/// V30：真机预览（LAY-108–111）——本机连接、按未写回的值生成、写回本书、竖排提示。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('12 款机型都有机身尺寸，屏幕放得进机身', () {
    expect(kindleDevices.length, 12);
    for (final k in kindleDevices) {
      expect(k.bodyWidthMm, greaterThan(k.screenWidthMm), reason: k.id);
      expect(k.bodyHeightMm, greaterThan(k.screenHeightMm), reason: k.id);
    }
    final kpw5 = kindleDevices.firstWhere((k) => k.id == 'kpw5');
    expect(kpw5.bodyWidthMm, 124.6);
    expect(kpw5.screenWidthMm, closeTo(104.6, .1));
    expect(kindleDevices.where((k) => k.grip).map((k) => k.id), [
      'oasis1',
      'oasis2',
      'oasis3',
      'scribe',
    ]);
  });

  testWidgets('真机预览：连接只认口令与本机，按未写回的值生成，写回本书，排版页关闭后停止', (t) async {
    t.view.physicalSize = const Size(1500, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String root;
    final paragraph =
        '子曰：学而时习之，不亦｜说《yuè》乎？有朋自远方来，不亦乐乎？'
        '人不知而不愠，不亦｜君子《・・》乎？孔子卒年73岁，全书共20篇。';
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp('v30-kindle-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final text = StringBuffer();
      for (final chapter in ['第一章 学而', '第二章 为政', '第三章 八佾']) {
        text.writeln(chapter);
        for (var i = 0; i < 30; i++) {
          text.writeln(paragraph);
        }
      }
      final file = File('$root/论语长样.txt')..writeAsStringSync('$text');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    final id = state.currentId;
    final host = _Host();
    var show = true;
    late StateSetter toggle;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              toggle = setState;
              return show
                  ? LayoutPage(
                      library: library,
                      bookId: id,
                      navigation: LayoutNavigationGuard(),
                      pickPresetFile: () async => null,
                      pickPresetDestination: () async => null,
                      importCss: () async => null,
                      kindlePreview: host,
                    )
                  : const SizedBox();
            },
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('layout-kindle-preview'));
    for (var i = 0; i < 300 && button.evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(find.byKey(const ValueKey('layout-vertical-hint')), findsNothing);
    await t.tap(button);
    for (var i = 0; i < 100 && host.launched.isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
    expect(host.launched, hasLength(1));
    final url = host.launched.single;
    expect(url.host, '127.0.0.1');
    // 组件测试默认把 HttpClient 换成一律返回 400 的替身；这里要真实连接本机。
    final client = HttpOverrides.runWithHttpOverrides(
      HttpClient.new,
      _RealHttp(),
    );
    addTearDown(() => client.close(force: true));

    Future<(int, String)> get(Uri uri, {String? hostHeader}) async {
      final request = await client.getUrl(uri);
      if (hostHeader != null) request.headers.set('host', hostHeader);
      final response = await request.close();
      return (response.statusCode, await utf8.decodeStream(response));
    }

    Future<Map<String, dynamic>> post(String name, Object body) async {
      final request = await client.postUrl(url.resolve('api/$name'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      expect(response.statusCode, 200, reason: name);
      return jsonDecode(await utf8.decodeStream(response))
          as Map<String, dynamic>;
    }

    // 连接的处理在测试的假时钟里运行：请求放到后台真实时钟里发，同时不停 pump 让它处理。
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
      // 组件首页与安全边界。
      final (code, html) = await get(url);
      expect(code, 200);
      expect(html, contains('真机预览'));
      final base = 'http://127.0.0.1:${url.port}';
      expect((await get(Uri.parse('$base/'))).$1, 403);
      expect((await get(Uri.parse('$base/wrong-token/'))).$1, 403);
      expect((await get(url, hostHeader: 'evil.example:${url.port}')).$1, 403);
      expect(
        (await get(Uri.parse('$url%2e%2e/%2e%2e/flutter/pubspec.yaml'))).$1,
        403,
      );
      expect((await get(url.resolve('plugin.json'))).$1, 200);

      // 状态：12 款机型与当前排版值。
      final (_, raw) = await get(url.resolve('api/state'));
      final st = jsonDecode(raw) as Map;
      expect((st['devices'] as List).length, 12);
      expect((st['devices'] as List).first['bodyWidthMm'], 117.0);
      final kpw5 = (st['devices'] as List).firstWhere((d) => d['id'] == 'kpw5');
      expect(kpw5['topBezelMm'], 9.7);
      expect(kpw5['logo'], 'light');
      expect(st['values']['writing_mode'], 'horizontal');

      // 按未写回的值生成：内容是竖排，本书设置不变。
      final r = await post('render', {
        'values': {'writing_mode': 'vertical', 'vertical_digits': 2},
      });
      expect(r['ok'], true, reason: '${r['message']}');
      final content = await get(url.resolve('${r['base']}${r['content']}'));
      expect(content.$1, 200);
      expect(content.$2, contains('<rt>yuè</rt>'));
      expect(content.$2, contains('<span class="tcy">73</span>'));
      final css = RegExp(r'href="([^"]+\.css)"')
          .firstMatch(content.$2)!
          .group(1)!;
      final style = await get(url.resolve('${r['base']}$css'));
      expect(style.$2, contains('writing-mode: vertical-rl'));
      expect(state.production.settings(id)['writing_mode'], 'horizontal');
      // 给浏览器里的分页检查留一份真实生成内容（竖排正文与样式）。
      final sample = Directory('../artifacts/v30-kindle-sample');
      if (sample.existsSync()) sample.deleteSync(recursive: true);
      File('${sample.path}/${r['content']}')
        ..createSync(recursive: true)
        ..writeAsStringSync(content.$2);
      File('${sample.path}/$css')
        ..createSync(recursive: true)
        ..writeAsStringSync(style.$2);

      // 阅读器参数：与小预览同一套。
      final m = await post('metrics', {
        'device': 'kpw5',
        'level': 8,
        'margin': 'narrow',
        'spacing': 'medium',
        'values': {'line_height': 1.2},
      });
      expect(m['rootPx'] as num, greaterThan(10));
      expect(m['measured'], true);

      // 写回本书：经排版页原有保存流程。
      final applied = await post('apply', {
        'values': {'writing_mode': 'vertical', 'font_size': 120},
      });
      expect(applied['ok'], true, reason: '${applied['message']}');
      expect(
        (await post('apply', {
          'values': {'title': '改名'},
        }))['ok'],
        false,
      );
    });
    for (var i = 0; i < 100; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      if (state.production.settings(id)['writing_mode'] == 'vertical') break;
    }
    expect(state.production.settings(id)['writing_mode'], 'vertical');
    expect(state.production.settings(id)['font_size'], 120);
    await t.pump();
    expect(find.byKey(const ValueKey('layout-vertical-hint')), findsOneWidget);

    // 排版页关闭后连接停止。
    toggle(() => show = false);
    await t.pump();
    await network(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await expectLater(get(url), throwsA(isA<SocketException>()));
    });
    library.dispose();
    state.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('找不到 Edge 时提示原因，不启动', (t) async {
    t.view.physicalSize = const Size(1500, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v30-noedge-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')..writeAsStringSync('第一章 开始\n正文。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final host = _Host(edge: null);
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: LayoutPage(
            library: library,
            bookId: state.currentId,
            navigation: LayoutNavigationGuard(),
            pickPresetFile: () async => null,
            pickPresetDestination: () async => null,
            importCss: () async => null,
            kindlePreview: host,
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('layout-kindle-preview'));
    for (var i = 0; i < 300 && button.evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await t.tap(button);
    await t.pump();
    expect(host.launched, isEmpty);
    expect(find.textContaining('没有找到 Microsoft Edge'), findsOneWidget);
  });
}
