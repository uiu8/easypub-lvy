import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/conversion_preflight_runner.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

/// 手工生成 24 位 BMP（自下而上、每行补齐 4 字节）。
Uint8List bmp(int width, int height) {
  final row = (width * 3 + 3) & ~3;
  final size = 54 + row * height;
  final b = ByteData(size);
  b.setUint8(0, 0x42);
  b.setUint8(1, 0x4D);
  b.setUint32(2, size, Endian.little);
  b.setUint32(10, 54, Endian.little);
  b.setUint32(14, 40, Endian.little);
  b.setInt32(18, width, Endian.little);
  b.setInt32(22, height, Endian.little);
  b.setUint16(26, 1, Endian.little);
  b.setUint16(28, 24, Endian.little);
  b.setUint32(34, row * height, Endian.little);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final at = 54 + y * row + x * 3;
      b.setUint8(at, 60);
      b.setUint8(at + 1, 120);
      b.setUint8(at + 2, 200);
    }
  }
  return b.buffer.asUint8List();
}

bool _contains(List<int> haystack, String needle) {
  final n = ascii.encode(needle);
  outer:
  for (var i = 0; i + n.length <= haystack.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// V24：封面与插图自动转换为 Kindle 可用格式（OUT-078）；GIF、BMP 可选（RES-049）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('转换说明逐张列出格式、尺寸与原因', () {
    expect(
      imageConversionLine({
        'path': r'C:\图\封面.webp',
        'from_format': 'webp',
        'from_width': 3200,
        'from_height': 4800,
        'to_format': 'jpg',
        'to_width': 1600,
        'to_height': 2400,
        'reasons': ['format', 'oversize'],
      }),
      '封面.webp：WebP 3200×4800 → JPEG 1600×2400（Kindle 不支持该格式、缩小到 2560×1600 以内）',
    );
  });

  test('BMP 封面：预检列出“将转换 1 张图片”，EPUB 成品里是 JPEG，原图不变（OUT-078、RES-049）', () async {
    final root = (await Directory('../artifacts').createTemp('v24-images-'))
        .absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('${root.path}/样书.txt')
        ..writeAsStringSync('第一章 开始\n正文。\n');
      await library.importFiles([file.path]);
      final id = state.currentId;
      final cover = File('${root.path}/封面.bmp')..writeAsBytesSync(bmp(6, 9));
      final original = cover.readAsBytesSync();
      final info = library.openBookInformation(id);
      await info.apply(await info.preview({'cover_path': cover.path}));
      info.dispose();

      final session = LegacyConversionSession(state);
      try {
        final plan = await session.preview(
          ConversionRequest(
            books: [id],
            directory: root.path,
            format: 'EPUB',
            runChecks: true,
          ),
        );
        expect(
          plan.previewed,
          true,
          reason: plan.findings.map((e) => e.detail).join('\n'),
        );
        final titles = plan.findings.map((f) => f.title).toList();
        expect(titles, contains('将转换 1 张图片'), reason: '$titles');
        final note = plan.findings.singleWhere((f) => f.title == '将转换 1 张图片');
        expect(note.category, 'resources');
        expect(
          note.detail,
          contains('封面.bmp：BMP 6×9 → JPEG 6×9（Kindle 不支持该格式）'),
        );
        final result = (await session.commit(
          plan,
          acknowledgeWarnings: true,
        )).single;
        expect(result.complete, true, reason: result.detail);
        final epub = File(result.path).readAsBytesSync();
        expect(_contains(epub, '.jpg'), true);
        expect(_contains(epub, '.bmp'), false);
      } finally {
        session.dispose();
      }
      expect(cover.readAsBytesSync(), original);
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
