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

PreviewStyle style(String first) => PreviewStyle(
  title: const TextStyle(fontSize: 20),
  body: const TextStyle(fontSize: 16),
  align: TextAlign.start,
  indent: 32,
  paragraphSpacing: 4,
  titleSpacing: 12,
  padding: EdgeInsets.zero,
  sceneBreak: 'keep',
  firstParagraph: first,
);

/// V49：章首段落样式（LAY-119）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('小预览：标题后与场景分隔后的第一段不缩进，首字放大只对文字开头生效', () {
    expect(firstParagraphStyles.keys, ['normal', 'no_indent', 'large_initial']);
    const paragraphs = ['', '　　正文甲', '正文乙', '＊＊＊', '“对白”', '正文丙'];
    List<PreviewPiece> pieces(String first) => paginatePreview(
      title: '第一章',
      paragraphs: paragraphs,
      style: style(first),
      page: const Size(400, 2000),
    ).single;
    final normal = pieces('normal');
    expect(normal.where((p) => !p.title).every((p) => p.indent), true);
    expect(normal.any((p) => p.initial), false);
    for (final first in ['no_indent', 'large_initial']) {
      final list = pieces(first);
      final unindented = list.where((p) => !p.title && !p.indent).toList();
      expect(unindented.map((p) => p.text), ['正文甲', '“对白”'], reason: first);
      expect(
        unindented.every((p) => p.initial),
        first == 'large_initial',
        reason: first,
      );
      expect(list.firstWhere((p) => p.text == '正文乙').indent, true);
      expect(list.firstWhere((p) => p.text == '正文丙').indent, true);
    }
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

  testWidgets('排版页：章首段落默认“同正文”，点选“首字放大”后自动保存', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v49-layout-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')
        ..writeAsStringSync('第一章 开始\n正文甲。\n正文乙。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    expect(state.production.settings(id)['first_paragraph_style'], 'normal');
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
    await t.tap(find.byKey(const ValueKey('layout-row-first_paragraph_style')));
    await t.pump();
    final control = find.byKey(const ValueKey('layout-first_paragraph_style'));
    await until(t, () => control.evaluate().isNotEmpty);
    final segmented = t.widget<DeskSegmented<String>>(
      find.descendant(
        of: control,
        matching: find.byType(DeskSegmented<String>),
      ),
    );
    expect(segmented.value, 'normal');
    expect(segmented.options, firstParagraphStyles);
    final help = t.widget<Tooltip>(
      find.descendant(
        of: find.byKey(const ValueKey('layout-help-first-paragraph')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(help.message, contains('段首是引号等标点时只取消缩进'));
    await t.ensureVisible(control);
    await t.pump();
    await t.tap(find.descendant(of: control, matching: find.text('首字放大')));
    await until(
      t,
      () =>
          state.production.settings(id)['first_paragraph_style'] ==
          'large_initial',
    );
    expect(t.takeException(), isNull);
  });

  test('真实转换：EPUB、AZW3、KFX 中章首段落不缩进且首字放大，KFX 通过 Bokai 校验', () async {
    final root = (await Directory('../artifacts').createTemp('v49-output-'))
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
        ..writeAsStringSync(
          '第一章 雾起\n港口起雾了。\n正文甲。\n＊＊＊\n“明天出海吗？”\n正文乙。\n第二章 旧码头\n天亮了。\n',
        );
      final original = file.readAsBytesSync();
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
      final change = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'first_paragraph_style': {'op': 'set', 'value': 'large_initial'},
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
      expect(css, contains('.first-para { text-indent: 0; }'));
      expect(css, contains('.first-char { font-size: 1.6em;'));
      // 两章各一个标题后首段，加上场景分隔后的一段。
      expect('first-para'.allMatches(xhtml).length, 3);
      expect(xhtml, contains('<span class="first-char">港</span>口起雾了。'));
      expect(xhtml, contains('<span class="first-char">天</span>亮了。'));
      expect(
        xhtml,
        contains('first-para" data-source="true" data-eol="lf">“明天出海吗？”'),
      );
      expect(xhtml, contains('>　　正文甲。</p>'), reason: '其后的段落照常缩进');

      final azw3 = await decode(outputs['AZW3']!, 'azw3');
      final azw3All = azw3.values.join('\n');
      expect(azw3All, contains('first-char'));
      expect(azw3All.replaceAll(' ', ''), contains('font-size:1.6em'));

      // KFX 转换时已通过 Bokai 的 validate all（样式覆盖率 100%）；解回后首字仍单独成段落内的一段。
      final kfx = await decode(outputs['KFX']!, 'kfx');
      final kfxAll = kfx.values.join('\n');
      expect(kfxAll, matches(RegExp(r'>港</span>口起雾了。')));
      expect(file.readAsBytesSync(), original);
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
