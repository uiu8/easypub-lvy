import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 第 0 条记录的全部 EXTH 记录（类型 → 文本）。
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
      utf8.decode(bytes.sublist(offset + 8, offset + size), allowMalformed: true),
    );
    offset += size;
  }
  return result;
}

bool containsAscii(List<int> bytes, String text) {
  final needle = ascii.encode(text);
  outer:
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

Future<String> convert(
  PrototypeState state,
  String id,
  String directory,
  String format, {
  required bool original,
  String? type,
}) async {
  Directory(directory).createSync(recursive: true);
  final session = LegacyConversionSession(state);
  try {
    final plan = await session.preview(
      ConversionRequest(
        books: [id],
        directory: directory,
        format: format,
        engine: format == 'EPUB'
            ? ''
            : Platform.environment[format == 'KFX'
                  ? 'EASYPUB_TEST_BOKAI'
                  : 'EASYPUB_TEST_KINDLING']!,
        generateCover: true,
        runChecks: false,
        keepOriginalEpub: original ? {id} : const {},
        outputOptions: type == null ? const {} : {'document_type': type},
      ),
    );
    expect(
      plan.previewed,
      true,
      reason: plan.findings.map((f) => '${f.title}：${f.detail}').join('\n'),
    );
    if (original) {
      expect(plan.findings.where((f) => f.title == '保持原格式'), isNotEmpty);
    }
    final result = (await session.commit(plan, acknowledgeWarnings: true)).single;
    expect(result.complete, true, reason: '$format $type: ${result.detail}');
    return result.path;
  } finally {
    session.dispose();
  }
}

/// 保持原格式时 Kindle 内容类型（EBOK / PDOC）照样写进成品。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('保持原格式：AZW3、MOBI、KFX 的内容类型读回与所选一致', () async {
    final root = (await Directory('../artifacts').createTemp('original-type-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    final txt = File('$root/样书.txt')
      ..writeAsStringSync('第一章 开始\n　　第一章正文。\n第二章 继续\n　　第二章正文。\n');
    await library.importFiles([txt.path]);
    final txtId = state.currentId;
    // 用软件排版做出一本 EPUB，再当原稿导入。
    final epub = await convert(state, txtId, '$root/first', 'EPUB', original: false);
    await library.importFiles([epub]);
    final id = state.currentId;
    expect(id, isNot(txtId));

    final evidence = <String, Object?>{};
    // 对照：软件排版的 KFX 选 PDOC，确认按字节查得到类型（验证读回方法本身）。
    final reference = File(
      await convert(state, id, '$root/layout-KFX-PDOC', 'KFX', original: false, type: 'PDOC'),
    ).readAsBytesSync();
    expect(containsAscii(reference, 'PDOC'), true);
    expect(containsAscii(reference, 'EBOK'), false);

    for (final format in ['AZW3', 'MOBI', 'KFX']) {
      for (final type in ['EBOK', 'PDOC']) {
        final path = await convert(
          state,
          id,
          '$root/original-$format-$type',
          format,
          original: true,
          type: type,
        );
        final bytes = File(path).readAsBytesSync();
        if (format == 'KFX') {
          final other = type == 'PDOC' ? 'EBOK' : 'PDOC';
          expect(containsAscii(bytes, type), true, reason: '$format $type');
          expect(containsAscii(bytes, other), false, reason: '$format $type');
          evidence['$format-$type'] = {'contains': type, 'absent': other};
        } else {
          final records = exth(bytes);
          expect(records[501], [type], reason: '$format $type');
          evidence['$format-$type'] = {'exth_501': records[501]};
        }
      }
    }
    // ignore: avoid_print
    print(jsonEncode(evidence));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
