import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

/// V28 样书：《论语》选段（公有领域），带注音、着重号和不同位数的数字。
const sample =
    '第一章 ｜学而《xué ér》\n'
    '子曰：学而时习之，不亦｜说《yuè》乎？有朋自远方来，不亦乐乎？人不知而不愠，不亦｜君子《・・》乎？\n'
    '孔子卒年73岁，全书共20篇，约15000字，iPhone15不是古书。\n'
    '第二章 为政\n'
    '子曰：吾十有五而志于学，三十而立。孔子生于公元前551年。\n';

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

/// AZW3 第 0 条记录的全部 EXTH 记录（类型 → 文本）。
Map<int, List<String>> exth(List<int> raw) {
  final bytes = Uint8List.fromList(raw);
  final data = ByteData.sublistView(bytes);
  final start = data.getUint32(78);
  final at = start + 16 + data.getUint32(start + 20);
  expect(ascii.decode(bytes.sublist(at, at + 4)), 'EXTH');
  var offset = at + 12;
  final result = <int, List<String>>{};
  for (var i = 0; i < data.getUint32(at + 8); i++) {
    final type = data.getUint32(offset), size = data.getUint32(offset + 4);
    (result[type] ??= []).add(
      utf8.decode(
        bytes.sublist(offset + 8, offset + size),
        allowMalformed: true,
      ),
    );
    offset += size;
  }
  return result;
}

String joined(Map<String, String> files, String suffix) => files.entries
    .where((e) => e.key.toLowerCase().endsWith(suffix))
    .map((e) => e.value)
    .join('\n');

void main() {
  test('V28 vertical writing, upright digits, ruby and emphasis reach EPUB, AZW3 and KFX', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('vertical-markup-')).absolute;
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
        expect(result.complete, true, reason: result.detail);
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
        await library.savePatch({
          'check_after_import': false,
          'layout_defaults': {'writing_mode': 'vertical', 'vertical_digits': 2},
        }),
        true,
      );
      final source = File('${root.path}/论语选段.txt')..writeAsStringSync(sample);
      final original = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = state.currentId;
      expect(state.production.settings(id)['writing_mode'], 'vertical');
      expect(state.production.settings(id)['vertical_digits'], 2);

      // EPUB：OPF 声明竖排与从右往左；样式与正文里的标记。
      final epub = await convert(id, 'EPUB', '${root.path}/vertical');
      final files = await members(epub);
      final opf = joined(files, '.opf'), css = joined(files, '.css');
      final xhtml = joined(files, '.xhtml');
      expect(
        opf,
        contains('<meta name="primary-writing-mode" content="vertical-rl"/>'),
      );
      expect(opf, contains('page-progression-direction="rtl"'));
      expect(css, contains('writing-mode: vertical-rl'));
      expect(css, contains('text-combine-upright: all'));
      expect(css, contains('rt { font-size: 0.5em; }'));
      expect(css, contains('text-emphasis-style: filled dot'));
      expect(xhtml, contains('<ruby>说<rp>（</rp><rt>yuè</rt><rp>）</rp></ruby>'));
      expect(xhtml, contains('<span class="em-dot">君子</span>'));
      expect(
        xhtml,
        contains('<ruby>学而<rp>（</rp><rt>xué ér</rt><rp>）</rp></ruby>'),
      );
      expect(xhtml, contains('<span class="tcy">73</span>'));
      expect(xhtml, contains('<span class="tcy">20</span>'));
      expect(xhtml, contains('约15000字'));
      expect(xhtml, contains('iPhone15'));
      expect(xhtml, contains('公元前551年'));
      expect(xhtml, isNot(contains('｜')));
      // 目录只保留基础文字。
      final navigation =
          joined(files, '.ncx') +
          files.entries
              .where((e) => e.key.endsWith('nav.xhtml'))
              .map((e) => e.value)
              .join();
      expect(navigation, contains('第一章 学而'));
      expect(navigation, isNot(contains('xué')));
      evidence['epub'] = {'path': epub, 'opf_meta': true, 'spine_rtl': true};

      // AZW3（Kindling）：EXTH 525 / 527 与 KF8 内的注音。
      final azw3 = await convert(id, 'AZW3', '${root.path}/vertical');
      final records = exth(File(azw3).readAsBytesSync());
      expect(records[525], ['vertical-rl']);
      expect(records[527], ['rtl']);
      final fromAzw3 = await decode(azw3, 'azw3-decoded');
      final azw3Text = joined(fromAzw3, '.xhtml') + joined(fromAzw3, '.html');
      expect(azw3Text, contains('<rt>yuè</rt>'));
      expect(azw3Text, contains('em-dot'));
      expect(azw3Text, contains('tcy'));
      expect(joined(fromAzw3, '.css'), contains('vertical-rl'));
      evidence['azw3'] = {
        'path': azw3,
        'exth_525': records[525],
        'exth_527': records[527],
      };

      // KFX（Bokai）：读回的书保持竖排、注音和着重号。
      final kfx = await convert(id, 'KFX', '${root.path}/vertical');
      final fromKfx = await decode(kfx, 'kfx-decoded');
      final kfxAll = fromKfx.values.join('\n');
      expect(kfxAll, contains('vertical-rl'));
      expect(kfxAll, contains('yuè'));
      expect(kfxAll, contains('<rt'));
      expect(kfxAll, contains('text-emphasis'));
      evidence['kfx'] = {'path': kfx, 'decoded_members': fromKfx.keys.toList()};

      // 横排：注音与着重号照样生成，数字不做纵中横，OPF 不声明竖排。
      expect(
        await library.savePatch({
          'layout_defaults': {
            'writing_mode': 'horizontal',
            'vertical_digits': 2,
          },
        }),
        true,
      );
      // 全局默认只影响之后导入的书；已导入的书保持自己的值。
      expect(state.production.settings(id)['writing_mode'], 'vertical');
      final second = File('${root.path}/论语横排.txt')..writeAsStringSync(sample);
      expect((await library.importFiles([second.path])).single.succeeded, true);
      final flatId = state.currentId;
      expect(flatId, isNot(id));
      expect(state.production.settings(flatId)['writing_mode'], 'horizontal');
      final flat = await members(
        await convert(flatId, 'EPUB', '${root.path}/horizontal'),
      );
      expect(joined(flat, '.opf'), isNot(contains('primary-writing-mode')));
      expect(
        joined(flat, '.opf'),
        isNot(contains('page-progression-direction')),
      );
      expect(joined(flat, '.css'), isNot(contains('vertical-rl')));
      expect(joined(flat, '.xhtml'), isNot(contains('class="tcy"')));
      expect(joined(flat, '.xhtml'), contains('<rt>yuè</rt>'));
      expect(source.readAsBytesSync(), original);
    } finally {
      File(
        '${root.path}/evidence.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
