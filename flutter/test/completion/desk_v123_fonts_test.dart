import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/kindle_preview_server.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

/// 系统自带、允许嵌入的字体（只在测试里复制使用，不进仓库）。
const latinFont = r'C:\Windows\Fonts\arial.ttf';
const cjkFont = r'C:\Windows\Fonts\simhei.ttf';

Future<List<String>> entriesOf(String path) async {
  final result = await Process.run(
    Platform.environment['EASYPUB_TEST_PYTHON']!,
    [
      '-X',
      'utf8',
      '-c',
      r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
 for n in z.namelist():
  if n.lower().endswith('.css'): print('CSS ' + z.read(n).decode('utf-8','replace').replace('\n',' '))
  else: print('FILE ' + n)
''',
      path,
    ],
    stdoutEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return const LineSplitter().convert(result.stdout as String);
}

/// V123：真机预览导入字体（LAY-178）与嵌入字体（LAY-179）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  Future<void> until(WidgetTester t, bool Function() ready) async {
    for (var i = 0; i < 600; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (ready()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    fail('界面未就绪');
  }

  testWidgets('排版页：选字体文件、确认授权后写进本书，复制到程序数据目录，可取消嵌入', (t) async {
    t.view.physicalSize = const Size(1100, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String root, font;
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp('v123-font-'))
          .absolute
          .path;
      font = '$root/我的字体.ttf';
      File(latinFont).copySync(font);
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')
        ..writeAsStringSync('第一章 开始\n正文甲。\n第二章 下山\n正文乙。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
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
            pickFont: () async => font,
          ),
        ),
      ),
    );
    final pick = find.byKey(const ValueKey('layout-font-pick'));
    await until(t, () => pick.evaluate().isNotEmpty);
    expect(find.text('不嵌入'), findsOneWidget);
    final help = t.widget<Tooltip>(
      find.descendant(
        of: find.byKey(const ValueKey('layout-help-font')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(help.message, contains('出版商字体'));
    await t.ensureVisible(pick);
    await t.pump();
    await t.tap(pick);
    final confirm = find.byKey(const ValueKey('layout-font-confirm'));
    await until(t, () => confirm.evaluate().isNotEmpty);
    expect(find.textContaining('请确认你有权'), findsOneWidget);
    // Arial 没有汉字：确认框写明缺字，这些字按阅读器字体显示，仍可嵌入。
    expect(find.byKey(const ValueKey('layout-font-missing')), findsOneWidget);
    await t.tap(confirm);
    await until(
      t,
      () => state.production.settings(id)['font_resource'] != null,
    );
    final saved = Map<String, dynamic>.from(
      state.production.settings(id)['font_resource'] as Map,
    );
    expect(saved['license_confirmed'], true);
    expect(saved.containsKey('mode'), false, reason: 'Arial 允许裁剪，默认只嵌入用到的字');
    final copied = saved['path'] as String;
    expect(copied.replaceAll('\\', '/'), contains('/settings/embedded-fonts/'));
    expect(File(copied).readAsBytesSync(), File(font).readAsBytesSync());
    expect(copied, endsWith('${saved['sha256']}.ttf'));
    // 原文件删掉后，书里的设置仍指向副本。
    await t.runAsync(() async => File(font).deleteSync());
    final name = find.byKey(const ValueKey('layout-font-name'));
    await until(t, () => t.widget<Text>(name).data == 'Arial');
    final remove = find.byKey(const ValueKey('layout-font-remove'));
    await t.ensureVisible(remove);
    await t.pump();
    await t.tap(remove);
    await until(
      t,
      () => state.production.settings(id)['font_resource'] == null,
    );
    expect(t.takeException(), isNull);
  });

  test('原书自带的字体出现在排版页可选列表，读不了的格式不列出', () async {
    final root = (await Directory('../artifacts').createTemp('v123-orig-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')..writeAsStringSync('第一章 开始\n正文。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
      final session = library.openLayout(id);
      expect(session, isA<BookFontSource>());
      final fonts = session as BookFontSource;
      expect(fonts.originalFonts, isEmpty);
      final report = await fonts.inspectFont(latinFont);
      expect(report['family'], 'Arial');
      expect((report['embedding'] as Map)['outline_allowed'], true);
      final kept = await fonts.keepFont(latinFont, report['sha256'] as String);
      expect(File(kept).lengthSync(), File(latinFont).lengthSync());
      await expectLater(fonts.inspectFont('$root/样书.txt'), throwsA(anything));
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  test('真实转换：嵌入字体只放入用到的字，EPUB、AZW3、KFX 都能生成', () async {
    final root = (await Directory('../artifacts').createTemp('v123-embed-'))
        .absolute
        .path;
    final bokai = Platform.environment['EASYPUB_TEST_BOKAI']!;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港.txt')
        // 𠀀（扩展 B）黑体里没有：缺字不再阻止嵌入，按阅读器字体显示。
        ..writeAsStringSync('第一章 雾起\n正文甲。\n正文乙・𠀀。\n第二章 旧码头\n正文丙。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
      final fonts = library.openLayout(id) as BookFontSource;
      final report = await fonts.inspectFont(cjkFont);
      expect(
        (report['embedding'] as Map)['outline_allowed'],
        true,
        reason: '黑体的授权标记允许嵌入',
      );
      final kept = await fonts.keepFont(cjkFont, report['sha256'] as String);
      final change = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'font_resource': {
              'op': 'set',
              'value': {
                'path': kept,
                'face_index': 0,
                'sha256': report['sha256'],
                'license_confirmed': true,
              },
            },
          },
        },
      });
      expect(await state.production.confirm(change), true);
      expect(report['missing_count'], greaterThan(0));
      // 真机预览带嵌入字体也能生成（V123：原来书里有一个字体没有的字就生成失败）。
      final preview =
          await (library.openLayout(id) as LayoutDraftPreviewSession)
              .renderDraftPreview({});
      expect(
        Directory(preview.directory)
            .listSync(recursive: true)
            .where((f) => f.path.toLowerCase().endsWith('.ttf')),
        hasLength(1),
      );
      final outputs = <String, String>{};
      for (final format in ['EPUB', 'AZW3', 'KFX']) {
        final session = LegacyConversionSession(state);
        try {
          final plan = await session.preview(
            ConversionRequest(
              books: [id],
              directory: '$root/out',
              format: format,
              engine: switch (format) {
                'KFX' => bokai,
                'AZW3' => Platform.environment['EASYPUB_TEST_KINDLING']!,
                _ => '',
              },
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(plan.previewed, true);
          final result = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(result.complete, true, reason: '$format ${result.detail}');
          outputs[format] = result.path;
        } finally {
          session.dispose();
        }
      }
      final epub = await entriesOf(outputs['EPUB']!);
      final ttf = epub.where(
        (l) => l.startsWith('FILE ') && l.toLowerCase().endsWith('.ttf'),
      );
      expect(ttf, hasLength(1));
      expect(
        epub.where((l) => l.startsWith('CSS ')).join(),
        contains('font-family: "EasyPubEmbedded"'),
      );
      // 只放入用到的字：黑体原文件近 10 MB，成品远小于它。
      expect(File(outputs['EPUB']!).lengthSync(), lessThan(1024 * 1024));
      for (final f in ['AZW3', 'KFX']) {
        expect(File(outputs[f]!).lengthSync(), greaterThan(0));
      }
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  test('真机预览服务：导入字体只收字体文件，清单记名字与上次选择，可取回与移除', () async {
    final root = (await Directory('../artifacts').createTemp('v123-pv-'))
        .absolute
        .path;
    final server = KindlePreviewServer(
      pluginDirectory: '$root/plugin',
      state: () => {'title': '样书', 'reader': {'level': 8}},
      render: (_, _) => throw const FormatException('不用'),
      metrics: (_) => const {},
      apply: (_) async => null,
      fontDirectory: '$root/preview-fonts',
    );
    // 测试框架默认把 HttpClient 换成一律返回 400 的假实现；这里要连本机的预览服务。
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final client = HttpClient();
    try {
      final base = await server.start();
      Future<Map<String, dynamic>> call(
        String path, {
        Object? json,
        List<int>? bytes,
        String? name,
      }) async {
        final request = json == null && bytes == null
            ? await client.getUrl(base.resolve(path))
            : await client.postUrl(base.resolve(path));
        if (name != null) request.headers.set('X-Font-Name', name);
        if (json != null) {
          request.headers.contentType = ContentType.json;
          request.add(utf8.encode(jsonEncode(json)));
        }
        if (bytes != null) request.add(bytes);
        final response = await request.close();
        expect(response.statusCode, 200);
        return jsonDecode(await utf8.decodeStream(response))
            as Map<String, dynamic>;
      }

      var state = await call('api/state');
      expect(state['title'], '样书');
      expect(state['fonts'], isEmpty);
      final wrong = await call(
        'api/font-import',
        bytes: utf8.encode('不是字体'),
        name: Uri.encodeComponent('假.ttf'),
      );
      expect(wrong['ok'], false);
      expect(wrong['message'], contains('不是字体文件'));
      final imported = await call(
        'api/font-import',
        bytes: File(latinFont).readAsBytesSync(),
        name: Uri.encodeComponent('我的 Arial.ttf'),
      );
      expect(imported['ok'], true);
      final font = imported['font'] as Map;
      expect(font['name'], '我的 Arial');
      expect(font['file'], matches(RegExp(r'^[0-9a-f]{16}\.ttf$')));
      // 网页按这个地址载入字体。
      final get = await (await client.getUrl(
        base.resolve('fonts/${font['file']}'),
      )).close();
      expect(get.statusCode, 200);
      expect(get.headers.contentType?.mimeType, 'font/ttf');
      expect(
        (await get.fold<int>(0, (n, c) => n + c.length)),
        File(latinFont).lengthSync(),
      );
      await call('api/font-select', json: {'font': 'user:${font['id']}'});
      state = await call('api/state');
      expect(state['fonts'], hasLength(1));
      expect(state['reader_font'], 'user:${font['id']}');
      final removed = await call('api/font-remove', json: {'id': font['id']});
      expect(removed['fonts'], isEmpty);
      expect(
        File('$root/preview-fonts/${font['file']}').existsSync(),
        false,
      );
    } finally {
      client.close(force: true);
      await server.close();
    }
  });
}
