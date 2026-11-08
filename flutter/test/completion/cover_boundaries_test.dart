import 'dart:io';

import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_removal_test.dart' show fixture;

void main() {
  setUpAll(
    () => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test('B7 封面边界：CMYK、透明 PNG、裁切适配和失败不改变已保存值', () async {
    final (state, library, root) = await fixture();
    final info = library.openBookInformation(state.currentId);
    addTearDown(() {
      info.dispose();
      library.dispose();
      state.dispose();
    });
    for (final name in ['cmyk.jpg', 'transparent.png']) {
      final file = await File('../samples/b7-covers/$name').copy('$root/$name');
      final evidence = await info.inspectImage(file.absolute.path);
      expect([evidence.width, evidence.height], [16, 12]);
      for (final fit in ['contain', 'cover', 'fill']) {
        final preview = await info.preview({
          'cover_path': file.absolute.path,
          'cover_fit': fit,
          'cover_crop': {'x': 0.25, 'y': 0.25, 'width': 0.5, 'height': 0.5},
        });
        await info.apply(preview);
        expect(info.saved['cover_fit'], fit);
        expect(info.saved['cover_path'], file.absolute.path);
      }
    }
    final saved = info.saved;
    for (final name in ['corrupt.png', 'oversize.png']) {
      final path = File('../samples/b7-covers/$name').absolute.path;
      await expectLater(info.inspectImage(path), throwsA(anything));
      await expectLater(info.preview({'cover_path': path}), throwsA(anything));
      expect(info.saved, saved);
    }
    await expectLater(
      info.preview({
        'cover_crop': {'x': 0.8, 'y': 0.0, 'width': 0.5, 'height': 1.0},
      }),
      throwsA(anything),
    );
    expect(info.saved, saved);
  });
}
