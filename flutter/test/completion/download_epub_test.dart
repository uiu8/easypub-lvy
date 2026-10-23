// LIB-215 书源下载为 EPUB：真实书库与转换会话。TXT 加入书库后按全局默认排版生成 EPUB，放在同一文件夹。
import 'dart:io';

import 'package:easypub_desktop/desk/app/download_epub.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('下载的 TXT 按全局默认排版生成 EPUB，TXT 保留；转换忙时只入库', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('download-epub-'))
        .absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final session = LegacyConversionSession(state);
    try {
      await library.load();
      final layout = Map<String, Object?>.of(
        await state.resolvedFactoryLayout(),
      )..['font_size'] = 125;
      expect(
        await library.savePatch({
          'check_after_import': false,
          'layout_defaults': layout,
        }),
        true,
      );
      final folder = Directory('${root.path}/下载')..createSync();
      final txt = File('${folder.path}/剑来 - 烽火.txt')
        ..writeAsStringSync('第一章 开始\n　　山路很长。\n第二章 远行\n　　海风很轻。\n');
      final before = txt.readAsBytesSync();

      final busy = await exportDownloadAsEpub(
        library: library,
        session: session,
        path: txt.path,
        conversionBusy: true,
      );
      expect(busy.imported, true);
      expect(busy.error, contains('另一项转换正在进行'));
      expect(library.books.value, hasLength(1));

      final done = await exportDownloadAsEpub(
        library: library,
        session: session,
        path: txt.path,
      );
      expect(done.error, isNull);
      expect(done.imported, true);
      expect(library.books.value, hasLength(1), reason: '已在书库的书不重复导入');
      final epubs = folder
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.epub'))
          .toList();
      expect(epubs, hasLength(1));
      expect(txt.readAsBytesSync(), before, reason: 'TXT 保留不变');
      final css = await Process.run(
        Platform.environment['EASYPUB_TEST_PYTHON']!,
        [
          '-X',
          'utf8',
          '-c',
          "import sys,zipfile;z=zipfile.ZipFile(sys.argv[1]);print('\\n'.join(z.read(n).decode('utf-8') for n in z.namelist() if n.endswith('.css')))",
          epubs.single.path,
        ],
      );
      expect(css.exitCode, 0, reason: css.stderr.toString());
      expect('${css.stdout}', contains('125%'), reason: '用的是全局默认排版');
    } finally {
      session.dispose();
      await root.delete(recursive: true);
    }
  });
}
