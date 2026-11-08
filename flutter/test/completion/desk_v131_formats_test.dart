import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/output_formats.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';

/// V131：输出 TXT（OUT-089）；导入 AZW3 / MOBI（LIB-295）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('输出格式：TXT 与 EPUB 一样由程序内置生成，AZW3、MOBI、KFX 用转换器', () {
    expect(outputFormats, ['EPUB', 'AZW3', 'MOBI', 'KFX', 'TXT']);
    expect(usesKindleEngine('TXT'), false);
    expect(usesKindleEngine('EPUB'), false);
    expect(
      [
        for (final f in ['AZW3', 'MOBI', 'KFX']) usesKindleEngine(f),
      ],
      [true, true, true],
    );
    for (final ext in ['txt', 'epub', 'azw3', 'mobi', 'AZW3']) {
      expect(isSupportedBookImportPath('书.$ext'), true, reason: ext);
    }
    expect(isSupportedBookImportPath('书.kfx'), false);
    expect(bookFormatForPath('书.azw3'), 'AZW3');
    expect(bookFormatForPath('书.mobi'), 'MOBI');
  });

  test('真实转换：TXT 输出章节与正文齐全；生成的 AZW3、MOBI 再导入，正文与原稿一致；DRM 文件拒绝', () async {
    final root = (await Directory('../artifacts').createTemp('v131-formats-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File(
        '$root/雾港.txt',
      )..writeAsStringSync('第一章 雾起\n正文甲，“引号”与<尖括号>&符号。\n正文乙。\n第二章 旧码头\n正文丙。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
      final outputs = <String, String>{};
      for (final format in ['TXT', 'AZW3', 'MOBI']) {
        final session = LegacyConversionSession(state);
        try {
          final plan = await session.preview(
            ConversionRequest(
              books: [id],
              directory: '$root/out',
              format: format,
              engine: format == 'TXT'
                  ? ''
                  : Platform.environment['EASYPUB_TEST_KINDLING']!,
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(plan.previewed, true, reason: format);
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
      expect(outputs['TXT'], endsWith('.txt'));
      final text = File(outputs['TXT']!).readAsStringSync();
      for (final line in [
        '第一章 雾起',
        '正文甲，“引号”与<尖括号>&符号。',
        '正文乙。',
        '第二章 旧码头',
        '正文丙。',
      ]) {
        expect(text, contains(line));
      }
      expect(text, isNot(contains('<p')));

      // 把刚生成的 AZW3、MOBI 当作别处来的书导入：正文与原稿相同，格式记为 AZW3 / MOBI。
      for (final format in ['AZW3', 'MOBI']) {
        final copy = File(outputs[format]!)
            .copySync('$root/外来.${format.toLowerCase()}');
        final before = state.shelf.books.length;
        final imported = (await library.importFiles([copy.path])).single;
        expect(imported.succeeded, true, reason: format);
        expect(state.shelf.books.length, before + 1);
        final book = state.shelf.books.firstWhere(
          (b) => b.id == state.currentId,
        );
        expect(book.format, format);
        final body = File(book.source!.path).readAsStringSync();
        for (final line in ['第一章 雾起', '正文乙。', '第二章 旧码头', '正文丙。']) {
          expect(body, contains(line), reason: format);
        }
        // 原文件不改。
        expect(
          copy.readAsBytesSync(),
          File(outputs[format]!).readAsBytesSync(),
        );
      }

      // 带 DRM 的文件：PalmDOC 头的加密标志不为 0，直接拒绝。
      final drm = BytesBuilder()
        ..add(List.filled(60, 0))
        ..add('BOOKMOBI'.codeUnits)
        ..add(List.filled(8, 0))
        ..add([0, 1, 0, 0, 0, 88, 0, 0, 0, 0]);
      final record = Uint8List(0xF8);
      record[1] = 2;
      record[13] = 2;
      record.setRange(16, 20, 'MOBI'.codeUnits);
      record[23] = 0xE8;
      drm.add(record);
      final locked = File('$root/有保护.azw3')..writeAsBytesSync(drm.takeBytes());
      final rejected = (await library.importFiles([locked.path])).single;
      expect(rejected.succeeded, false);
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
