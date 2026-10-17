import 'dart:io';

import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('same EPUB reimport preserves edited and explicitly cleared fields across project reopen', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = await Directory.systemTemp.createTemp(
      'epub-metadata-regression-',
    );
    final file = File('${root.path}/source.epub');
    final made = await Process.run(
      Platform.environment['EASYPUB_TEST_PYTHON']!,
      [
        '-X',
        'utf8',
        '-c',
        r'''
import zipfile,sys
with zipfile.ZipFile(sys.argv[1],'w') as z:
 z.writestr('mimetype','application/epub+zip')
 z.writestr('META-INF/container.xml','<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>')
 z.writestr('book.opf','<package><metadata><title>原书名</title><creator>原作者</creator><description>原简介</description><publisher>原出版社</publisher><language>zh-CN</language></metadata><manifest><item id="c" href="text.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>')
 z.writestr('text.xhtml','<html><body><h1>第一章 开始</h1><p>正文</p></body></html>')
''',
        file.path,
      ],
    );
    expect(made.exitCode, 0, reason: '${made.stderr}');
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    expect((await library.importFiles([file.path])).single.succeeded, true);
    final id = library.books.value.single.id;
    final information = library.openBookInformation(id);
    addTearDown(information.dispose);
    expect(information.saved['description'], '原简介');
    await information.apply(
      await information.preview({
        'title': '手工书名',
        'author': '手工作者',
        'description': '手工简介',
        'publisher': '',
        'language': 'en',
      }),
    );
    final before = Map<String, Object?>.from(information.saved);
    final project = '${root.path}/edited.easypub.json';
    expect((await library.saveProject(project)).succeeded, true);
    expect((await library.importFiles([file.path])).single.succeeded, true);
    final afterReimport = library.openBookInformation(id);
    expect(afterReimport.saved, before);
    afterReimport.dispose();
    final reopened = PrototypeState(settingsDirectory: '${root.path}/reopened');
    final reopenedLibrary = LegacyLibraryAdapter(backend: reopened);
    addTearDown(() {
      reopenedLibrary.dispose();
      reopened.dispose();
    });
    await reopenedLibrary.load();
    expect((await reopenedLibrary.openProject(project)).succeeded, true);
    expect(
      (await reopenedLibrary.importFiles([file.path])).single.succeeded,
      true,
    );
    expect(reopenedLibrary.books.value, hasLength(1));
    expect(reopened.currentId, id);
    final finalSession = reopenedLibrary.openBookInformation(id);
    addTearDown(finalSession.dispose);
    expect(finalSession.saved, before);
    await finalSession.apply(
      await finalSession.preview({'description': '再次编辑'}),
    );
    expect(finalSession.saved['description'], '再次编辑');
  });
}
