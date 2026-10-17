import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

/// V36 样书：章前引言加三章（文字为本测试自拟）。
const sample =
    '这是一段写在第一章之前的引言。\n'
    '第一章 我祖上封过神\n'
    '吕文均坐在出租屋里，盯着桌上那面铜镜看了很久。\n'
    '窗外的雨下了一整夜。\n'
    '第二章 雨夜\n'
    '天亮的时候，雨停了。\n'
    '第三章：铜镜\n'
    '镜子里的人也在看他。\n';

/// 每种样式在样式表里必须出现的写法（与 Rust `heading_rules` 对应）。
const expected = {
  'classic': ['font-size: x-large', 'border-bottom: 1px dotted #c1ccc0'],
  'amazon': ['font-size: 1.2em', 'border-bottom: 2px dashed #c7c7c7'],
  'publisher': ['font-size: 1.6em', 'margin: 2em 0 1em'],
  'two_line': ['font-size: 1.2em', '.chapter-label { font-size: 0.7em; }'],
  'light_novel': ['font-size: 1.5em', 'border-bottom: 1px solid #888888'],
};

/// 读出 zip 内所有文本成员。
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
 print(json.dumps({n:z.read(n).decode('utf-8','replace') for n in z.namelist() if n.rsplit('.',1)[-1].lower() in ('opf','xhtml','html','htm','css','ncx')},ensure_ascii=False))
''',
      path,
    ],
    stdoutEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return Map<String, String>.from(jsonDecode(result.stdout as String) as Map);
}

String joined(Map<String, String> files, String suffix) => files.entries
    .where((e) => e.key.toLowerCase().endsWith(suffix))
    .map((e) => e.value)
    .join('\n');

/// 含章节标题的正文文件：文件名 → 其中的章名。每个文件最多一章即“每章单独一个文件”。
Map<String, List<String>> chapterFiles(Map<String, String> files) {
  final result = <String, List<String>>{};
  for (final e in files.entries) {
    final name = e.key.toLowerCase();
    if (!RegExp(r'\.x?html?$').hasMatch(name)) continue;
    // 目录文件列出全部章名，不算正文。
    if (name.contains('nav') ||
        name.contains('toc') ||
        e.value.contains('epub:type="toc"')) {
      continue;
    }
    for (final title in ['我祖上封过神', '雨夜', '铜镜']) {
      if (RegExp('第.章[ ：]?(</span><br ?/>)?[^<]*$title').hasMatch(e.value)) {
        (result[e.key] ??= []).add(title);
      }
    }
  }
  return result;
}

void main() {
  test('V36 five chapter heading styles and one file per chapter reach EPUB, AZW3 and KFX', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('heading-styles-')).absolute;
    final bokai = Platform.environment['EASYPUB_TEST_BOKAI']!;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final evidence = <String, Object?>{};
    Future<String> convert(String id, String format, String directory) async {
      final session = LegacyConversionSession(state);
      try {
        final plan = await session.preview(
          ConversionRequest(
            books: [id],
            directory: directory,
            format: format,
            engine: format == 'KFX'
                ? bokai
                : Platform.environment['EASYPUB_TEST_KINDLING']!,
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
        expect(result.complete, true, reason: '$format: ${result.detail}');
        return result.path;
      } finally {
        session.dispose();
      }
    }

    Future<Map<String, String>> decode(String path, String name) async {
      final target = '${root.path}/$name.epub';
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
      expect(
        await library.savePatch({'check_after_import': false}),
        true,
      );
      for (final style in headingStyles.keys) {
        expect(
          await library.savePatch({
            'layout_defaults': {'heading_style': style},
          }),
          true,
        );
        final source = File('${root.path}/$style.txt')
          ..writeAsStringSync(sample);
        expect((await library.importFiles([source.path])).single.succeeded, true);
        final id = state.currentId;
        expect(state.production.settings(id)['heading_style'], style);
        final directory = '${root.path}/$style';

        // EPUB：样式表、精排两行的结构、每章（与章前引言）各一个文件。
        final epub = await members(await convert(id, 'EPUB', directory));
        final css = joined(epub, '.css');
        for (final part in expected[style]!) {
          expect(css, contains(part), reason: style);
        }
        expect(css, contains('text-align: center'));
        expect(
          css,
          contains('.chapter-start, .volume-start, .front-start { break-before: page;'),
        );
        final xhtml = joined(epub, '.xhtml');
        if (style == 'two_line') {
          expect(
            xhtml,
            contains('<span class="chapter-label">第一章 </span><br/>我祖上封过神'),
          );
          expect(
            xhtml,
            contains('<span class="chapter-label">第三章：</span><br/>铜镜'),
          );
        } else {
          expect(xhtml, isNot(contains('chapter-label')));
          expect(xhtml, contains('>第一章 我祖上封过神</h'));
        }
        final epubChapters = chapterFiles(epub);
        expect(epubChapters.length, 3, reason: '$epubChapters');
        expect(epubChapters.values.every((t) => t.length == 1), true);
        final intro = epub.entries
            .where((e) => e.value.contains('写在第一章之前的引言'))
            .map((e) => e.key)
            .single;
        expect(epubChapters.containsKey(intro), false);

        // AZW3（Kindling）：解回后样式与“每章一个文件”都在。
        final azw3 = await convert(id, 'AZW3', directory);
        final fromAzw3 = await decode(azw3, '$style-azw3');
        final azw3Css = joined(fromAzw3, '.css');
        final azw3Chapters = chapterFiles(fromAzw3);
        expect(azw3Chapters.length, 3, reason: '$style AZW3 $azw3Chapters');
        expect(azw3Chapters.values.every((t) => t.length == 1), true);
        if (style == 'two_line') {
          expect(
            joined(fromAzw3, 'html'),
            matches(RegExp(r'chapter-label[^>]*>第一章 </span><br\s*/?>')),
          );
        }

        // KFX（Bokai）：转换时 Bokai 自带的 validate all 必须通过（convert 已检查）；
        // 解回后标题居中、边框与精排两行的小字仍在。
        final kfx = await convert(id, 'KFX', directory);
        final fromKfx = await decode(kfx, '$style-kfx');
        final kfxAll = fromKfx.values.join('\n');
        expect(kfxAll, contains('我祖上封过神'));
        final kfxChapters = chapterFiles(fromKfx);
        evidence[style] = {
          'epub_chapter_files': epubChapters.keys.toList(),
          'azw3': azw3,
          'azw3_chapter_files': azw3Chapters.keys.toList(),
          'azw3_css_has_heading': expected[style]!
              .every((part) => azw3Css.replaceAll(' ', '').contains(part.replaceAll(' ', ''))),
          'kfx': kfx,
          'kfx_chapter_files': kfxChapters.keys.toList(),
          'kfx_has_dotted': kfxAll.contains('dotted'),
          'kfx_has_dashed': kfxAll.contains('dashed'),
          'kfx_has_solid': kfxAll.contains('solid'),
          'kfx_has_label': kfxAll.contains('第一章'),
        };
        expect(kfxChapters.length, 3, reason: '$style KFX $kfxChapters');
        if (style == 'two_line') {
          expect(kfxAll, matches(RegExp(r'第一章 </span><br\s*/?>我祖上封过神')));
        }
        if (style == 'classic') expect(kfxAll, contains('dotted'));
        if (style == 'amazon') expect(kfxAll, contains('dashed'));
        expect(source.readAsStringSync(), sample);
      }
    } finally {
      File(
        '${root.path}/evidence.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
