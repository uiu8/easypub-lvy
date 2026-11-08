import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/metadata/cover_editor_page.dart';

/// 读出 zip 内的文本成员与图片个数。
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
 out={n:z.read(n).decode('utf-8','replace') for n in z.namelist() if n.rsplit('.',1)[-1].lower() in ('opf','xhtml','html','htm','css')}
 out['__images__']=str(sum(1 for n in z.namelist() if n.rsplit('.',1)[-1].lower() in ('png','jpg','jpeg','gif')))
 print(json.dumps(out,ensure_ascii=False))
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

/// V74：章节样式包（LAY-130）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('排版页：选“古典”后应用到本书；去掉一项、改卷页边框、停用', (t) async {
    t.view.physicalSize = const Size(1100, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String root;
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp('v74-layout-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')
        ..writeAsStringSync('第一章 开始\n正文甲。\n第二章 继续\n正文乙。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    expect(state.production.settings(id)['chapter_style'], isNull);
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
            pickStylePack: () async => null,
            pickStylePackDestination: (_) async => null,
          ),
        ),
      ),
    );
    final tabs = find.byKey(const ValueKey('layout-tabs'));
    await until(t, () => tabs.evaluate().isNotEmpty);
    await t.tap(find.descendant(of: tabs, matching: find.text('标题')).first);
    await t.pump();
    final classic = find.byKey(const ValueKey('layout-chapter-style-classic'));
    await until(t, () => classic.evaluate().isNotEmpty);
    await t.ensureVisible(classic);
    await t.pump();
    await t.tap(classic);
    Map<String, dynamic>? style() =>
        (state.production.settings(id)['chapter_style'] as Map?)
            ?.cast<String, dynamic>();
    await until(t, () => style() != null);
    expect(style()!['name'], '古典');
    expect(style()!['head_images'], hasLength(2));
    expect(style()!['volume_frame'], 'double');
    for (final p in [
      ...style()!['head_images'] as List,
      style()!['title_rule'],
    ]) {
      expect('$p', contains('style_packs'));
      expect(File('$p').existsSync(), true);
    }
    // 去掉章末装饰。
    final drop = find.byKey(
      const ValueKey('layout-chapter-style-drop-chapter_end'),
    );
    await until(t, () => drop.evaluate().isNotEmpty);
    await t.ensureVisible(drop);
    await t.pump();
    await t.tap(drop);
    await until(t, () => style()?['chapter_end'] == null);
    expect(style()!['title_rule'], isNotNull);
    // 卷页边框改为单线。
    final frame = find.byKey(
      const ValueKey('layout-chapter-style-volume_frame'),
    );
    await t.ensureVisible(frame);
    await t.pump();
    await t.tap(find.descendant(of: frame, matching: find.text('单线')));
    await until(t, () => style()?['volume_frame'] == 'single');
    // 停用。
    final none = find.byKey(const ValueKey('layout-chapter-style-none'));
    await t.ensureVisible(none);
    await t.pump();
    await t.tap(none);
    await until(t, () => style() == null);
    expect(t.takeException(), isNull);
  });

  test('真实转换：EPUB、AZW3、KFX 中章头图轮换、标题装饰线、章末装饰与卷页边框，KFX 通过 Bokai 校验', () async {
    final root = (await Directory('../artifacts').createTemp('v74-output-'))
        .absolute
        .path;
    final bokai = Platform.environment['EASYPUB_TEST_BOKAI']!;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
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
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港.txt')
        ..writeAsStringSync('第一章 雾起\n港口起雾了。\n第二章 旧码头\n天亮了。\n第三章 归航\n船回来了。\n');
      final original = file.readAsBytesSync();
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
      final built = await state.production.productionRequest(
        jsonEncode({
          'op': 'chapter_style',
          'action': 'builtin',
          'id': 'classic',
          'dir': Directory('$root/packs').absolute.path,
        }),
      );
      final change = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'chapter_style': {'op': 'set', 'value': built['style']},
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
      final epub = await members(outputs['EPUB']!);
      final xhtml = epub.entries
          .where((e) => e.key.endsWith('.xhtml'))
          .map((e) => e.value)
          .join('\n');
      final css = epub.entries
          .where((e) => e.key.endsWith('.css'))
          .map((e) => e.value)
          .join('\n');
      expect('class="chapter-head-image'.allMatches(xhtml).length, 3);
      expect('<p class="title-rule">'.allMatches(xhtml).length, 3);
      expect('<p class="chapter-end">'.allMatches(xhtml).length, 3);
      expect(css, contains('.volume-heading { border: 3px double;'));
      // 封面 1 张 + 章头图 2 张 + 装饰线 + 章末装饰。
      expect(int.parse(epub['__images__']!), greaterThanOrEqualTo(5));

      final azw3 = await decode(outputs['AZW3']!, 'azw3');
      final azw3All = azw3.values.join('\n');
      expect(azw3All, contains('title-rule'));
      expect(azw3All, contains('chapter-end'));
      expect(int.parse(azw3['__images__']!), greaterThanOrEqualTo(5));

      // KFX 转换时已通过 Bokai 的 validate all；解回后图片仍在。
      final kfx = await decode(outputs['KFX']!, 'kfx');
      expect(int.parse(kfx['__images__']!), greaterThanOrEqualTo(5));
      expect(file.readAsBytesSync(), original);
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('文字封面：书用了带背景的样式包时可选“样式包背景”，采用后通过校验', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String root, id;
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp('v74-cover-'))
          .absolute
          .path;
      // 载入中文字体，生成的封面可直接当效果图看。
      await (FontLoader('Microsoft YaHei')..addFont(
            File('C:/Windows/Fonts/msyh.ttc')
                .readAsBytes()
                .then((b) => b.buffer.asByteData()),
          ))
          .load();
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港来信.txt')
        ..writeAsStringSync('第一章 雾起\n港口起雾了。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
      final built = await state.production.productionRequest(
        jsonEncode({
          'op': 'chapter_style',
          'action': 'builtin',
          'id': 'plain',
          'dir': '$root/packs',
        }),
      );
      expect((built['style'] as Map)['cover_background'], isNotNull);
      final change = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'chapter_style': {'op': 'set', 'value': built['style']},
          },
        },
      });
      expect(await state.production.confirm(change), true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final info = library.openBookInformation(id);
    addTearDown(info.dispose);
    expect(info.styleCoverBackground, isNotNull);
    CoverEditorResult? result;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: CoverEditorPage(
            session: info,
            title: '雾港来信',
            author: '林岚',
            series: '',
            path: null,
            fit: 'contain',
            crop: null,
            design: null,
            startWithText: true,
            pickImage: () async => null,
            onReturn: (value) => result = value,
          ),
        ),
      ),
    );
    final pack = find.byKey(const ValueKey('cover-template-pack'));
    await until(t, () => pack.evaluate().isNotEmpty);
    await t.tap(pack);
    await t.pump();
    await t.tap(find.text('采用并返回'));
    await until(t, () => result != null);
    final adopted = result!;
    expect(adopted.design!['style'], 'pack-background-v1');
    // 生成的封面底部是样式包背景的山色，不是经典模板的绿色渐变。
    await t.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        await File(adopted.path).readAsBytes(),
      );
      final image = (await codec.getNextFrame()).image;
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final at = (1550 * image.width + 600) * 4;
      final (r, g, b) = (
        bytes.getUint8(at),
        bytes.getUint8(at + 1),
        bytes.getUint8(at + 2),
      );
      image.dispose();
      expect(
        (r - 0xb9).abs() < 12 && (g - 0xb0).abs() < 12 && (b - 0xa0).abs() < 12,
        true,
        reason: '$r,$g,$b',
      );
      // 采用到书里：Rust 校验接受新模板。
      await info.apply(
        await info.preview({
          'cover_path': adopted.path,
          'cover_design': adopted.design,
          'cover_fit': adopted.fit,
        }),
      );
      expect(
        (state.production.settings(id)['cover_design'] as Map)['style'],
        'pack-background-v1',
      );
    });
    expect(t.takeException(), isNull);
  });
}
