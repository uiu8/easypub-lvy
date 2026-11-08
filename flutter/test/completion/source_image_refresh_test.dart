import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> makeImageEpub(String path, {required bool updated}) async {
  final result = await Process.run(
    Platform.environment['EASYPUB_TEST_PYTHON']!,
    [
      '-X',
      'utf8',
      '-c',
      r'''
import sys,zipfile,struct,zlib
changed=sys.argv[2]=='new'
c=lambda t,d:struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
pixel=bytes.fromhex('2244ddff' if changed else 'dd4422ff')
png=bytes.fromhex('89504e470d0a1a0a')+c(b'IHDR',struct.pack('>IIBBBBB',2,2,8,6,0,0,0))+c(b'IDAT',zlib.compress((bytes([0])+pixel*2)*2))+c(b'IEND',b'')
count=4 if changed else 3
with zipfile.ZipFile(sys.argv[1],'w') as z:
 z.writestr('mimetype','application/epub+zip')
 z.writestr('META-INF/container.xml','<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>')
 imgs=''.join('<item id="i%d" href="i%d.png" media-type="image/png"/>'%(n,n) for n in range(count))
 z.writestr('book.opf','<package><metadata><title>'+('新来源书名' if changed else '旧来源书名')+'</title><language>zh-CN</language></metadata><manifest><item id="c" href="text.xhtml" media-type="application/xhtml+xml"/>'+imgs+'</manifest><spine><itemref idref="c"/></spine></package>')
 z.writestr('text.xhtml','<html><body><h1>第一章 开始</h1><p>保持正文</p>'+''.join('<img src="i%d.png" alt="插图%d"/>'%(n,n) for n in range(count))+'</body></html>')
 for n in range(count): z.writestr('i%d.png'%n,png)
''',
      path,
      updated ? 'new' : 'old',
    ],
  );
  expect(result.exitCode, 0, reason: result.stderr.toString());
}

void main() {
  test('resource-only EPUB adoption preserves text edits, manual image choices and one-step history, exports real new pixels', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('source-images81-')).absolute.path;
    final path = '$root/source.epub';
    await makeImageEpub(path, updated: false);
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    expect((await library.importFiles([path])).single.succeeded, true);
    final id = state.currentId, sourceId = state.current.source!.sourceId;
    final images = (state.production.settings(id)['illustrations'] as List)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    expect(images, hasLength(3));
    final oldBytes = await File(images.first['path'] as String).readAsBytes();
    images[1]['caption'] = '手工说明';
    images.removeLast();
    expect(
      await state.production.confirm(
        await state.production.previewChanges({
          id: {
            'op': 'patch',
            'fields': {
              'illustrations': {'op': 'set', 'value': images},
            },
          },
        }),
      ),
      true,
    );
    final chapters = library.openChapters(id);
    final tree = await chapters.read(0);
    await chapters.confirm(
      await chapters.preview(
        tree,
        RenameChapter(tree.nodes.first.id, '第一章 手工章节'),
      ),
    );
    final history = jsonDecode(jsonEncode(state.manuscript.effectiveHistories[id]));
    await makeImageEpub(path, updated: true);
    var p = await library.previewSourceRefresh(id);
    expect(p.bodyChanged, false);
    expect(p.imagesChanged, true);
    expect(state.production.settings(id)['illustrations'], images);
    final outcome = await library.applySourceRefresh(
      p,
      fields: {'title'},
      replaceBody: false,
      replaceImages: true,
    );
    expect(state.current.source!.sourceId, sourceId);
    expect(state.manuscript.effectiveHistories[id], history);
    final updated = (state.production.settings(id)['illustrations'] as List)
        .cast<Map>();
    expect(updated, hasLength(3));
    expect(updated[1], images[1]);
    expect(updated[0]['path'], isNot(images[0]['path']));
    final newBytes = await File(updated[0]['path'] as String).readAsBytes();
    expect(newBytes, isNot(oldBytes));
    expect(state.production.settings(id)['title'], '新来源书名');
    expect(
      await state.production.confirm(
        await state.production.previewChanges({
          id: {'op': 'undo'},
        }),
      ),
      true,
    );
    expect(state.production.settings(id)['title'], '旧来源书名');
    expect(state.production.settings(id)['illustrations'], images);
    expect(
      await state.production.confirm(
        await state.production.previewChanges({
          id: {'op': 'redo'},
        }),
      ),
      true,
    );
    expect(
      (await library.saveProject('$root/updated.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/updated.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openChapters(id).read(0)).nodes.first.title,
      '第一章 手工章节',
    );
    final conversion = library.openConversion();
    try {
      final proposal = await conversion.preview(
        ConversionRequest(
          books: [id],
          directory: root,
          format: 'EPUB',
          runChecks: false,
        ),
      );
      expect(proposal.previewed, true);
      final output = (await conversion.commit(
        proposal,
        acknowledgeWarnings: true,
      )).single;
      expect(output.phase, 'complete', reason: output.detail);
      final checked = await Process.run(
        Platform.environment['EASYPUB_TEST_PYTHON']!,
        [
          '-X',
          'utf8',
          '-c',
          "import sys,zipfile,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); b=E.fromstring(z.read('EPUB/body.xhtml')); n={'h':'http://www.w3.org/1999/xhtml'}; assert [x.text for x in b.findall('.//h:h1',n)]==['第一章 手工章节']; assert len(b.findall('.//h:img',n))==3; data=[z.read(p) for p in z.namelist() if p.endswith('.png')]; assert open(sys.argv[2],'rb').read() in data; assert open(sys.argv[3],'rb').read() in data",
          output.path,
          updated[0]['path'] as String,
          images[1]['path'] as String,
        ],
      );
      expect(checked.exitCode, 0, reason: checked.stderr.toString());
    } finally {
      conversion.dispose();
    }
    p = await library.previewSourceRefresh(id);
    expect(p.imagesChanged, false);
    expect((await library.openProject(outcome.recoveryPath!)).succeeded, true);
    expect(state.production.settings(id)['illustrations'], images);
    expect(await File(images.first['path'] as String).readAsBytes(), oldBytes);
  });
}
