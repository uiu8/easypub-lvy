import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

Map<int, List<String>> exth(Uint8List bytes, int record) {
  final data = ByteData.sublistView(bytes);
  final start = data.getUint32(78 + record * 8);
  final at = start + 16 + data.getUint32(start + 20);
  expect(ascii.decode(bytes.sublist(at, at + 4)), 'EXTH');
  final count = data.getUint32(at + 8);
  var offset = at + 12;
  final result = <int, List<String>>{};
  for (var i = 0; i < count; i++) {
    final type = data.getUint32(offset), size = data.getUint32(offset + 4);
    if ([100, 101, 103, 104, 105, 106, 108, 503, 524].contains(type)) {
      (result[type] ??= []).add(
        utf8.decode(bytes.sublist(offset + 8, offset + size)),
      );
    }
    offset += size;
  }
  return result;
}

int boundary(Uint8List bytes) {
  final data = ByteData.sublistView(bytes), start = dataStart(bytes);
  final at = start + 16 + data.getUint32(start + 20);
  var offset = at + 12;
  for (var i = 0; i < data.getUint32(at + 8); i++) {
    if (data.getUint32(offset) == 121) return data.getUint32(offset + 8);
    offset += data.getUint32(offset + 4);
  }
  throw StateError('Missing KF8 boundary');
}

int dataStart(Uint8List bytes) => ByteData.sublistView(bytes).getUint32(78);
void main() {
  test(
    'real MOBI and AZW3 retain bibliography in every Kindle section',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = await Directory('../artifacts')
          .createTemp('completion-kindle-metadata-');
      final state = PrototypeState(
        settingsDirectory: '${root.absolute.path}/settings',
      );
      final library = LegacyLibraryAdapter(backend: state);
      final evidence = <Map<String, Object?>>[];
      try {
        await library.load();
        await library.savePatch({'check_after_import': false});
        final source = File('${root.absolute.path}/书目信息.txt')
          ..writeAsStringSync('第一章 开始\n合成正文。\n第二章 结束\n结束正文。\n');
        final original = source.readAsBytesSync();
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        final id = state.currentId;
        final cases = [
          {
            'title': '测试书',
            'author': '测试作者',
            'publisher': '中文出版社',
            'description': '这是非空简介。',
            'isbn': '9787111123456',
            'translator': '测试译者',
            'category': '小说',
            'publication_date': '2026-10-04',
            'language': 'zh-CN',
          },
          {
            'title': 'A & B <书>',
            'author': '作者 & 合著者',
            'publisher': '出版 & 发行 <甲>',
            'description': '第一行 & <标签>\n第二行：引号“正文”。',
            'isbn': '9787111123456',
            'translator': '译者 & 校者',
            'category': '长篇 & 小说',
            'publication_date': '2026-10-04',
            'language': 'zh-CN',
          },
        ];
        for (var i = 0; i < cases.length; i++) {
          final values = cases[i];
          final info = library.openBookInformation(id);
          await info.apply(await info.preview(values));
          info.dispose();
          for (final format in ['MOBI', 'AZW3']) {
            final session = LegacyConversionSession(state);
            try {
              final plan = await session.preview(
                ConversionRequest(
                  books: [id],
                  directory: '${root.absolute.path}/$i-$format',
                  format: format,
                  engine: Platform.environment['EASYPUB_TEST_KINDLING']!,
                  generateCover: true,
                  runChecks: false,
                ),
              );
              expect(
                plan.previewed,
                true,
                reason: plan.findings.map((x) => x.detail).join('\n'),
              );
              final output = (await session.commit(
                plan,
                acknowledgeWarnings: true,
              )).single;
              expect(output.complete, true, reason: output.detail);
              final bytes = await File(output.path).readAsBytes();
              final records = [0, if (format == 'MOBI') boundary(bytes)];
              for (final record in records) {
                final metadata = exth(bytes, record);
                for (final field in {
                  503: 'title',
                  100: 'author',
                  101: 'publisher',
                  103: 'description',
                  104: 'isbn',
                  108: 'translator',
                  105: 'category',
                  106: 'publication_date',
                  524: 'language',
                }.entries) {
                  expect(
                    metadata[field.key],
                    contains(values[field.value]),
                    reason: '$format section $record ${field.value}',
                  );
                }
              }
              expect(
                await Directory('${root.absolute.path}/$i-$format')
                    .list()
                    .where((e) => e is Directory)
                    .toList(),
                isEmpty,
              );
              evidence.add({
                'format': format,
                'case': i,
                'sections': records,
                'path': output.path,
                'bytes': bytes.length,
              });
            } finally {
              session.dispose();
            }
          }
        }
        expect(source.readAsBytesSync(), original);
      } finally {
        await File(
          Platform.environment['EASYPUB_KINDLE_METADATA_EVIDENCE'] ??
              '../artifacts/completion-kindle-metadata-results.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
        library.dispose();
        state.dispose();
      }
    },
  );
}
