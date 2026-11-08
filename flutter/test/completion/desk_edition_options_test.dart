import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_layout_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, List<int>> unzip(List<int> bytes) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  var end = bytes.length - 22;
  while (data.getUint32(end, Endian.little) != 0x06054b50) {
    end--;
  }
  var at = data.getUint32(end + 16, Endian.little);
  final files = <String, List<int>>{};
  for (var i = 0; i < data.getUint16(end + 10, Endian.little); i++) {
    final method = data.getUint16(at + 10, Endian.little),
        size = data.getUint32(at + 20, Endian.little),
        length = data.getUint16(at + 28, Endian.little);
    final name = utf8.decode(bytes.sublist(at + 46, at + 46 + length));
    final local = data.getUint32(at + 42, Endian.little);
    final start =
        local +
        30 +
        data.getUint16(local + 26, Endian.little) +
        data.getUint16(local + 28, Endian.little);
    final body = bytes.sublist(start, start + size);
    files[name] = method == 0 ? body : ZLibDecoder(raw: true).convert(body);
    at +=
        46 +
        length +
        data.getUint16(at + 30, Endian.little) +
        data.getUint16(at + 32, Endian.little);
  }
  return files;
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test('第4、7批：设置与预设贯通，五格式生成并读回 EPUB2 和 TXT', () async {
    final root = (await Directory('../artifacts').createTemp('edition47-'))
        .absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    final input = File('${root.path}/sample.txt')
      ..writeAsStringSync('第一章 开始\n中文正文。\n第二章 后记\n后记正文。\n');
    await library.importFiles([input.path]);
    final id = state.currentId;
    final layout = LegacyLayoutSession(state, id);
    final options = {
      'max_long': 1200,
      'max_short': 900,
      'quality': 65,
      'png_to_jpeg': true,
      'grayscale': true,
      'preserve_cover': true,
      'recompress_jpeg': true,
    };
    await layout.apply(
      await layout.preview({
        'image_options': options,
        'visible_toc': true,
        'navigation_options': {
          'toc_title': '章节列表',
          'toc_position': 'back',
          'toc_filter': '后记',
        },
      }),
    );
    expect(state.production.settings(id)['image_options'], options);
    await layout.savePreset('图片压缩测试', {'image_options': options});
    expect(
      layout.presets
          .singleWhere((p) => p.name == '图片压缩测试')
          .values['image_options'],
      options,
    );
    final estimate = await layout.estimateImages(options);
    expect(estimate['before'], 0);
    expect(estimate['after'], 0);
    layout.dispose();
    final project = '${root.path}/options.easypub.json';
    expect((await library.saveProject(project)).succeeded, true);
    expect((await library.openProject(project)).succeeded, true);
    expect(state.production.settings(id)['image_options'], options);
    for (final format in ['EPUB', 'TXT', 'AZW3', 'MOBI', 'KFX']) {
      final out = Directory('${root.path}/$format')..createSync();
      final session = LegacyConversionSession(state);
      if (format == 'EPUB') {
        await session.preview(
          ConversionRequest(
            books: [id],
            directory: out.path,
            format: format,
            generateCover: true,
            runChecks: false,
          ),
        );
      }
      final plan = await session.preview(
        ConversionRequest(
          books: [id],
          directory: out.path,
          format: format,
          engine: format == 'KFX'
              ? Platform.environment['EASYPUB_TEST_BOKAI']!
              : ['AZW3', 'MOBI'].contains(format)
              ? Platform.environment['EASYPUB_TEST_KINDLING']!
              : '',
          generateCover: true,
          runChecks: false,
          outputOptions: format == 'EPUB'
              ? {'epub_version': 2}
              : format == 'TXT'
              ? {'txt_encoding': 'gbk', 'txt_newline': 'windows'}
              : {'document_type': format == 'KFX' ? 'EBOK' : 'PDOC'},
        ),
      );
      expect(
        plan.previewed,
        true,
        reason: '$format: ${plan.findings.map((f) => f.detail).join('; ')}',
      );
      final output = (await session.commit(
        plan,
        acknowledgeWarnings: true,
      )).single;
      expect(output.complete, true, reason: '$format: ${output.detail}');
      final bytes = await File(output.path).readAsBytes();
      if (format == 'EPUB') {
        final files = unzip(bytes);
        final opf = utf8.decode(files['EPUB/package.opf']!);
        expect(opf, contains('version="2.0"'));
        expect(files.containsKey('EPUB/kindling.ncx'), true);
        expect(utf8.decode(files['EPUB/toc.xhtml']!), contains('章节列表'));
      }
      if (format == 'TXT') {
        expect(bytes, containsAllInOrder([13, 10]));
        expect(() => utf8.decode(bytes), throwsFormatException);
      }
      session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
