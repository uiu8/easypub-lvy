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
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/widgets.dart';

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

const sample =
    '第一章 苏醒\n'
    '　　他刚醒来，脑中响起一个声音。\n'
    '【叮！检测到宿主苏醒，新手礼包已发放。】\n'
    '【当前修为：炼气一层】\n'
    '　　窗外月色正好，他低声念道：\n'
    '床前明月光，疑是地上霜。\n'
    '举头望明月，低头思故乡。\n'
    '——李白《静夜思》\n'
    '——他愣住了，说不出话。\n'
    '　　念完，他推门而出。\n';

/// V50：系统提示（LAY-121）与诗词（LAY-122）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('识别规则与 Rust 一致；小预览分类：系统提示成框、诗句与署名、署名后的“——”对白仍是正文', () {
    for (final yes in ['【叮！新手礼包已发放。】', '　【当前修为：炼气一层】', '【力量：10】 【敏捷：8】']) {
      expect(isSystemLine(yes), true, reason: yes);
    }
    for (final no in ['【】', '【叮】他愣了一下', '他看到【提示】', '【未闭合', '【甲【乙】】', '']) {
      expect(isSystemLine(no), false, reason: no);
    }
    for (final yes in ['床前明月光，疑是地上霜。', '　春风得意马蹄疾，一日看尽长安花', '白日依山尽，黄河入海流！']) {
      expect(isVerseLine(yes), true, reason: yes);
    }
    for (final no in [
      '他推门而出，雾散了。',
      '床前明月光，疑是霜。',
      'abcde，fghij。',
      '床前明月光。',
      '好好好好好，好好好好好，好好好好好。',
    ]) {
      expect(isVerseLine(no), false, reason: no);
    }
    expect(isVerseAttribution('——李白《静夜思》'), true);
    expect(isVerseAttribution('——'), false);
    expect(isVerseAttribution('—李白'), false);
    expect(systemBlockStyles.keys, ['off', 'box', 'indent']);
    expect(verseBlockStyles.keys, ['off', 'center', 'indent']);

    final lines = sample.trimRight().split('\n');
    final pieces = paginatePreview(
      title: lines.first,
      paragraphs: lines.skip(1).toList(),
      style: const PreviewStyle(
        title: TextStyle(fontSize: 20),
        body: TextStyle(fontSize: 16),
        align: TextAlign.start,
        indent: 32,
        paragraphSpacing: 4,
        titleSpacing: 12,
        padding: EdgeInsets.all(8),
        systemBlock: 'box',
        verseBlock: 'center',
      ),
      page: const Size(400, 3000),
    ).single;
    expect(pieces.skip(1).map((p) => p.kind), [
      '',
      'system',
      'system',
      '',
      'verse',
      'verse',
      'by',
      '',
      '',
    ]);
    expect(
      pieces.where((p) => p.kind.isNotEmpty).every((p) => !p.indent),
      true,
    );
  });

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

  testWidgets('排版页：系统提示默认加框、诗词默认居中，点选后自动保存', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v50-layout-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')..writeAsStringSync(sample);
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    expect(state.production.settings(id)['system_block_style'], 'box');
    expect(state.production.settings(id)['verse_block_style'], 'center');
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
    for (final (field, value, options, help, tap, saved) in [
      (
        'system_block_style',
        'box',
        systemBlockStyles,
        '行中间夹着【】的句子不算',
        '缩进',
        'indent',
      ),
      (
        'verse_block_style',
        'center',
        verseBlockStyles,
        '自由体诗、歌词识别不了',
        '不识别',
        'off',
      ),
    ]) {
      await t.tap(find.byKey(ValueKey('layout-row-$field')));
      await t.pump();
      final control = find.byKey(ValueKey('layout-$field'));
      await until(t, () => control.evaluate().isNotEmpty);
      final segmented = t.widget<DeskSegmented<String>>(
        find.descendant(
          of: control,
          matching: find.byType(DeskSegmented<String>),
        ),
      );
      expect(segmented.value, value);
      expect(segmented.options, options);
      final tooltip = t.widget<Tooltip>(
        find.descendant(
          of: find.byKey(ValueKey('layout-help-$field')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tooltip.message, contains(help));
      await t.ensureVisible(control);
      await t.pump();
      await t.tap(find.descendant(of: control, matching: find.text(tap)));
      await until(t, () => state.production.settings(id)[field] == saved);
    }
    expect(t.takeException(), isNull);
  });

  test('真实转换：EPUB、AZW3、KFX 中系统提示成框、诗句居中、署名靠右，KFX 通过 Bokai 校验', () async {
    final root = (await Directory('../artifacts').createTemp('v50-output-'))
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
      final file = File('$root/苏醒.txt')..writeAsStringSync(sample);
      final original = file.readAsBytesSync();
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
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
      expect(
        css,
        contains(
          '.system-block { margin: 0.8em 0; padding: 0.4em 0.8em; border: 1px solid; }',
        ),
      );
      expect(
        css,
        contains('.verse-block { margin: 0.8em 0; text-align: center; }'),
      );
      expect(css, contains('.verse-block .verse-by { text-align: right; }'));
      expect(
        xhtml,
        contains(
          '<div class="system-block"><p class="text-line system-line" data-source="true" data-eol="lf">【叮！',
        ),
      );
      expect('class="text-line system-line"'.allMatches(xhtml).length, 2);
      expect('class="text-line verse-line"'.allMatches(xhtml).length, 2);
      expect(
        xhtml,
        contains(
          '<p class="text-line verse-by" data-source="true" data-eol="lf">——李白《静夜思》</p></div>',
        ),
      );
      expect(xhtml, contains('>　　——他愣住了，说不出话。</p>'), reason: '署名后的对白仍是正文');

      final azw3 = (await decode(outputs['AZW3']!, 'azw3')).values.join('\n');
      expect(azw3, contains('system-block'));
      expect(azw3, contains('verse-by'));

      // KFX 转换时已通过 Bokai 的 validate all（样式覆盖率 100%）。
      final kfx = (await decode(outputs['KFX']!, 'kfx')).values.join('\n');
      expect(kfx, contains('床前明月光，疑是地上霜。'));
      expect(kfx.replaceAll(' ', ''), contains('border'));
      expect(file.readAsBytesSync(), original);
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
