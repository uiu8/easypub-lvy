import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/kindle_preview_launcher.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';

const sample =
    '第一章 开始\n妖兽倒地。\n【叮！击杀成功，经验+120】\n他收剑入鞘。\n叮！\n【苍白的正义】\n'
    '【攻击力：20-25】\n【终极圣炎：附带30点伤害】\n正文。\n第二章 继续\n【力量：10】 【敏捷：8】\n【体质：12】\n结尾。\n';

/// 读出 zip 内的文本成员。
Future<Map<String, String>> members(String path) async {
  final result = await Process.run(
    Platform.environment['EASYPUB_TEST_PYTHON']!,
    [
      '-X',
      'utf8',
      '-c',
      r'''
import json,sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
 print(json.dumps({n:z.read(n).decode('utf-8','replace') for n in z.namelist() if n.rsplit('.',1)[-1].lower() in ('opf','xhtml','html','htm','css')},ensure_ascii=False))
''',
      path,
    ],
    stdoutEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return Map<String, String>.from(jsonDecode(result.stdout as String) as Map);
}

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

Future<(PrototypeState, LegacyLibraryAdapter, String, String)> book(
  String tag,
) async {
  final root = (await Directory('../artifacts').createTemp('v77-$tag-'))
      .absolute
      .path;
  final state = PrototypeState(settingsDirectory: '$root/settings');
  final library = LegacyLibraryAdapter(backend: state);
  await library.load();
  await library.savePatch({'check_after_import': false});
  final file = File('$root/系统流.txt')..writeAsStringSync(sample);
  expect((await library.importFiles([file.path])).single.succeeded, true);
  return (state, library, root, state.currentId);
}

/// V77：系统提示分类样式（LAY-132）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('界面预设与 Rust 一致；新书默认分类样式', () async {
    final (state, library, _, id) = await book('defaults');
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final listed = await state.production.productionRequest(
      jsonEncode({'op': 'block_styles'}),
    );
    final presets = (listed['presets'] as List).cast<Map>();
    expect(presets.map((p) => p['id']).toSet(), blockStylePresets.keys.toSet());
    for (final p in presets) {
      expect(p['style'], blockStylePresets[p['id']], reason: '${p['id']}');
      // V119 起有两类都可用的预设（kind 为 both），两张名称表都收了它们。
      final names = p['kind'] == 'panel' ? panelPresetNames : notePresetNames;
      expect(names[p['id']], p['name']);
    }
    final settings = state.production.settings(id);
    expect(settings['system_block_style'], 'styled');
    expect(settings['system_styles'], defaultSystemStyles());
    expect(describeSystemStyles(settings['system_styles']), '单行提示条 · 面板标题面板');
  });

  testWidgets('排版页：分类样式下换单行提示与面板样式，自动保存', (t) async {
    t.view.physicalSize = const Size(1100, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final made = await book('layout');
      (state, library, _, id) = made;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
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
          ),
        ),
      ),
    );
    final tabs = find.byKey(const ValueKey('layout-tabs'));
    await until(t, () => tabs.evaluate().isNotEmpty);
    await t.tap(find.descendant(of: tabs, matching: find.text('段落与识别')));
    await t.pump();
    final row = find.byKey(const ValueKey('layout-row-system_block_style'));
    await t.ensureVisible(row);
    expect(
      find.descendant(of: row, matching: find.text('单行提示条 · 面板标题面板')),
      findsOneWidget,
    );
    await t.tap(row);
    await t.pump();
    final note = find.byKey(const ValueKey('layout-system-note'));
    await until(t, () => note.evaluate().isNotEmpty);
    await t.ensureVisible(note);
    await t.pump();
    // V119 起选项变多，先把要点的那一项滚到可见处。
    final center = find.descendant(of: note, matching: find.text('居中强调'));
    await t.ensureVisible(center);
    await t.pump();
    await t.tap(center);
    Map? styles() => state.production.settings(id)['system_styles'] as Map?;
    await until(t, () => (styles()?['note'] as Map?)?['align'] == 'center');
    final panel = find.byKey(const ValueKey('layout-system-panel'));
    final rules = find.descendant(of: panel, matching: find.text('上下双线'));
    await t.ensureVisible(rules);
    await t.pump();
    await t.tap(rules);
    await until(t, () => (styles()?['panel'] as Map?)?['line'] == 'double');
    expect(styles()!['note'], blockStylePresets['center']);
    // 改回旧的“加框”：参数保留，模式换掉。
    final mode = find.byKey(const ValueKey('layout-system_block_style'));
    await t.ensureVisible(mode);
    await t.pump();
    await t.tap(find.descendant(of: mode, matching: find.text('加框')));
    await until(
      t,
      () => state.production.settings(id)['system_block_style'] == 'box',
    );
    expect(find.byKey(const ValueKey('layout-system-note')), findsNothing);
    expect(t.takeException(), isNull);
  });

  test('真实转换：EPUB、AZW3、KFX 中单行提示与两种面板，KFX 通过 Bokai 校验', () async {
    final (state, library, root, id) = await book('output');
    final bokai = Platform.environment['EASYPUB_TEST_BOKAI']!;
    Future<Map<String, String>> decode(String path, String name) async {
      final target = '$root/$name.epub';
      final run = await Process.run(
        bokai,
        ['convert', '--no-validate', path, target],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      return members(target);
    }

    try {
      for (final panelPreset in ['titled', 'rules']) {
        final change = await state.production.previewChanges({
          id: {
            'op': 'patch',
            'fields': {
              'system_styles': {
                'op': 'set',
                'value': {
                  'note': blockStylePresets['bar'],
                  'panel': blockStylePresets[panelPreset],
                },
              },
            },
          },
        });
        expect(await state.production.confirm(change), true);
        final outputs = <String, String>{};
        for (final format in ['EPUB', 'AZW3', 'KFX']) {
          final session = LegacyConversionSession(state);
          try {
            final plan = await session.preview(
              ConversionRequest(
                books: [id],
                directory: '$root/out-$panelPreset',
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
            expect(
              result.complete,
              true,
              reason: '$panelPreset $format ${result.detail}',
            );
            outputs[format] = result.path;
          } finally {
            session.dispose();
          }
        }
        final epub = await members(outputs['EPUB']!);
        final xhtml = epub.entries
            .where((e) => e.key.endsWith('.xhtml'))
            .map((e) => e.value)
            .join('\n');
        final css = epub.entries
            .where((e) => e.key.endsWith('.css'))
            .map((e) => e.value)
            .join('\n');
        expect(xhtml, contains('class="blk blk-note"'));
        expect('class="blk blk-panel'.allMatches(xhtml).length, 2);
        if (panelPreset == 'titled') {
          expect(xhtml, contains('blk-panel-title'));
          expect(xhtml, contains('<span class="blk-key">攻击力</span>'));
          expect(css, contains('.blk-panel .blk-panel-title {'));
        } else {
          expect(xhtml, isNot(contains('blk-panel-title')));
          expect(xhtml, contains('【攻击力：20-25】'), reason: '上下双线保留括号');
          expect(css, contains('border-top: 3px double;'));
        }
        final azw3 = (await decode(
          outputs['AZW3']!,
          'azw3-$panelPreset',
        )).values.join('\n');
        expect(azw3, contains('blk-panel'));
        final kfx = (await decode(
          outputs['KFX']!,
          'kfx-$panelPreset',
        )).values.join('\n');
        expect(kfx, contains('击杀成功'));
        expect(kfx, contains('终极圣炎'));
      }
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 6)));

  testWidgets('真机预览：分类样式的两个预设可切换并写回', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final made = await book('preview');
      (state, library, _, id) = made;
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
            kindlePreview: host,
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('layout-kindle-preview'));
    await until(t, () => button.evaluate().isNotEmpty);
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

    Future<String> css(Map<String, Object?> values) async {
      final r = await post('render', {'values': values});
      expect(r['ok'], true, reason: '${r['message']}');
      final base = '${r['base']}';
      final opf = await get(url.resolve('${base}package.opf'));
      return [
        for (final m in RegExp(r'href="([^"]+\.css)"').allMatches(opf))
          await get(url.resolve('$base${m.group(1)}')),
      ].join('\n');
    }

    await network(() async {
      final stateJson = jsonDecode(await get(url.resolve('api/state'))) as Map;
      final values = stateJson['values'] as Map;
      expect(values['system_block_style'], 'styled');
      expect(values['system_note_preset'], 'bar');
      expect(values['system_panel_preset'], 'titled');
      final page = await get(url);
      expect(page, contains('data-key="system_note_preset"'));
      expect(page, contains('styled:分类样式'));
      expect(await css({}), contains('.blk-panel .blk-panel-title {'));
      // V119 新增的细线楷体：灰色左细线、楷体。
      expect(
        await css({'system_panel_preset': 'quiet'}),
        contains('border-color: #888888;'),
      );
      expect(
        await css({'system_panel_preset': 'rules'}),
        contains('border-top: 3px double;'),
      );
      final applied = await post('apply', {
        'values': {'system_note_preset': 'center'},
      });
      expect(applied['ok'], true, reason: '${applied['message']}');
    });
    for (var i = 0; i < 200; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      final s = state.production.settings(id)['system_styles'] as Map?;
      if ((s?['note'] as Map?)?['align'] == 'center') break;
    }
    expect(
      (state.production.settings(id)['system_styles'] as Map)['note'],
      blockStylePresets['center'],
    );
    expect(t.takeException(), isNull);
  });
}
