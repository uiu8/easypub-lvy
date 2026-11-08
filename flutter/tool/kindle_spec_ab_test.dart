import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

/// 对照样文（本工具自拟）：三章，段落长短不一，含对白、场景分隔与“……”。
String sample(String label) {
  final para =
      '　　港口的雾从傍晚开始往岸上爬，先是吞掉了灯塔的底座，接着是码头边一排排生锈的铁桩。'
      '老周把船缆绕在桩上打了两个结，抬头看了一眼天色，又低头去收那张补了无数次的旧网。'
      '网眼里卡着几片海藻和一只指甲盖大小的螃蟹，他把螃蟹抠出来扔回水里，听见它落水时极轻的一声。';
  final short = '　　“明天还出海吗？”阿青在背后问。';
  final reply = '　　“看风。”老周说，“风往东走，就出。”';
  String chapter(String title, int n) => [
    title,
    for (var i = 0; i < n; i++) ...[para, short, reply],
    '＊＊＊',
    for (var i = 0; i < n; i++) para,
    '……',
    para,
  ].join('\n');
  return [
    '这是一本排版对照样书（$label）。在 Kindle 上请分别调大调小字号、调整行距与页边距，对比三本的反应。',
    chapter('第一章 雾起', 4),
    chapter('第二章 旧码头', 3),
    chapter('第三章 风往东走', 4),
  ].join('\n');
}

/// 三种排版：现行出厂默认、旧式固定像素、按 KDP 规范的写法。
final variants = <String, ({Map<String, Object?> layout, String css})>{
  '对照A-现行默认': (layout: <String, Object?>{}, css: ''),
  '对照B-固定像素': (
    layout: {
      'font_size': 20.0,
      'font_size_unit': 'px',
      'line_height': 1.8,
      'margin_left': 20.0,
      'margin_left_unit': 'px',
      'margin_right': 20.0,
      'margin_right_unit': 'px',
    },
    css: '',
  ),
  '对照C-规范写法': (
    layout: {
      'font_size': 100.0,
      'font_size_unit': '%',
      'line_height': 1.2,
      'margin_top': 0.0,
      'margin_top_unit': 'em',
      'margin_right': 0.0,
      'margin_right_unit': 'em',
      'margin_bottom': 0.0,
      'margin_bottom_unit': 'em',
      'margin_left': 0.0,
      'margin_left_unit': 'em',
    },
    css: 'body { line-height: normal; }',
  ),
};

/// 生成 Kindle 真机对照书：`tools/test_flutter.ps1 -TestPaths tool/kindle_spec_ab_test.dart`。
void main() {
  test('生成 Kindle 规范对照书（AZW3、KFX、EPUB）', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final out = Directory('../artifacts/kindle-spec-ab-20261015');
    if (out.existsSync()) out.deleteSync(recursive: true);
    out.createSync(recursive: true);
    final work = (await Directory('../artifacts').createTemp('kindle-ab-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$work/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final report = <String, Object?>{};
    try {
      await library.load();
      expect(await library.savePatch({'check_after_import': false}), true);
      for (final MapEntry(key: name, value: v) in variants.entries) {
        expect(
          await library.savePatch({'layout_defaults': v.layout}),
          true,
          reason: name,
        );
        final source = File('$work/$name.txt')..writeAsStringSync(sample(name));
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        final id = state.currentId;
        if (v.css.isNotEmpty) {
          final change = await state.production.previewChanges({
            id: {
              'op': 'patch',
              'fields': {
                'additional_css': {'op': 'set', 'value': v.css},
              },
            },
          });
          expect(await state.production.confirm(change), true);
        }
        final outputs = <String, String>{};
        for (final format in ['EPUB', 'AZW3', 'KFX']) {
          final session = LegacyConversionSession(state);
          try {
            final plan = await session.preview(
              ConversionRequest(
                books: [id],
                directory: out.absolute.path,
                format: format,
                engine: switch (format) {
                  'KFX' => Platform.environment['EASYPUB_TEST_BOKAI']!,
                  'AZW3' => Platform.environment['EASYPUB_TEST_KINDLING']!,
                  _ => '',
                },
                generateCover: true,
                runChecks: false,
              ),
            );
            expect(
              plan.previewed,
              true,
              reason: plan.findings.map((e) => e.detail).join('\n'),
            );
            final result = (await session.commit(
              plan,
              acknowledgeWarnings: true,
            )).single;
            expect(
              result.complete,
              true,
              reason: '$name $format ${result.detail}',
            );
            outputs[format] = result.path;
          } finally {
            session.dispose();
          }
        }
        // 记下 EPUB 里的正文样式，写进说明。
        final css = await Process.run(
          Platform.environment['EASYPUB_TEST_PYTHON']!,
          [
            '-X',
            'utf8',
            '-c',
            r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
 css=[z.read(n).decode('utf-8') for n in z.namelist() if n.endswith('.css')]
 print('\n'.join(l for c in css for l in c.splitlines() if l.startswith(('@page','body','p {'))))
''',
            outputs['EPUB']!,
          ],
          stdoutEncoding: utf8,
        );
        expect(css.exitCode, 0, reason: '${css.stderr}');
        report[name] = {
          'files': outputs.map(
            (k, p) => MapEntry(k, p.split(RegExp(r'[\\/]')).last),
          ),
          'body_css': (css.stdout as String).trim().split('\n'),
          'additional_css': v.css,
        };
      }
      File(
        '${out.path}/对照说明.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
