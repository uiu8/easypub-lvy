import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/output_task.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_removal_test.dart' show fixture;

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('body refresh preserves manual cover and makes old illustration anchors explicit while queued work blocks replacement', () async {
    final (state, library, root) = await fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId, path = state.current.path;
    final image = '$root/manual.png';
    final made = await Process.run(
      Platform.environment['EASYPUB_TEST_PYTHON']!,
      [
        '-c',
        "import sys,struct,zlib; c=lambda t,d:struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff); open(sys.argv[1],'wb').write(b'\\x89PNG\\r\\n\\x1a\\n'+c(b'IHDR',struct.pack('>IIBBBBB',2,2,8,6,0,0,0))+c(b'IDAT',zlib.compress((b'\\x00'+b'\\x11\\x77\\x44\\xff'*2)*2))+c(b'IEND',b''))",
        image,
      ],
    );
    expect(made.exitCode, 0, reason: made.stderr.toString());
    expect(
      await state.production.confirm(
        await state.production.previewChanges({
          id: {
            'op': 'patch',
            'fields': {
              'cover_path': {'op': 'set', 'value': image},
              'illustrations': {
                'op': 'set',
                'value': [
                  {
                    'path': image,
                    'source_line': 2,
                    'caption': '手工插图',
                    'alt': '',
                  },
                ],
              },
            },
          },
        }),
      ),
      true,
    );
    await File(path).writeAsString('第一章 新来源\n新正文\n');
    final p = await library.previewSourceRefresh(id);
    final task = OutputTask(
      bookId: id,
      title: '在途',
      sourceId: state.current.source!.sourceId,
      revision: 1,
      format: 'EPUB',
      outputPath: '$root/pending.epub',
    );
    state.outputs.tasks.add(task);
    await expectLater(
      library.applySourceRefresh(p, fields: {}, replaceBody: true),
      throwsFormatException,
    );
    task.phase = 'cancelled';
    task.finishedAt = DateTime.now();
    final result = await library.applySourceRefresh(
      p,
      fields: {},
      replaceBody: true,
    );
    expect(state.production.settings(id)['cover_path'], image);
    expect(
      state.production.settings(id)['metadata_origins']['cover_path']['source'],
      'manual',
    );
    final images = state.production.settings(id)['illustrations'] as List;
    expect(images.single['path'], image);
    expect(images.single['source_line'], isNull);
    final resources = library.openResources(id);
    expect((await resources.locate(0)).message, contains('尚未设置'));
    resources.dispose();
    expect((await library.openProject(result.recoveryPath!)).succeeded, true);
    expect(
      (state.production.settings(id)['illustrations'] as List)
          .single['source_line'],
      2,
    );
  });

  test('changed TXT reimport retains edits; explicit refresh keeps or replaces body with recoverable history', () async {
    final (state, library, root) = await fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId, path = state.current.path;
    final info = library.openBookInformation(id);
    await info.apply(
      await info.preview({
        'title': '手工书名',
        'author': '',
        'description': '手工简介',
      }),
    );
    info.dispose();
    final chapters = library.openChapters(id);
    final first = await chapters.read(0);
    await chapters.confirm(
      await chapters.preview(
        first,
        RenameChapter(first.nodes.first.id, '第一章 旧编辑'),
      ),
    );
    final oldSource = state.current.source!.sourceId;
    final oldHistory = jsonDecode(
      jsonEncode(state.manuscript.effectiveHistories[id]),
    );
    const changed = '第一章 新章节\n新的正文甲\n第二章 续篇\n新的正文乙\n';
    await File(path).writeAsString(changed);
    final reimport = (await library.importFiles([path])).single;
    expect(reimport.succeeded, true);
    expect(reimport.skipped, true);
    expect(reimport.message, contains('刷新来源'));
    expect(state.current.source!.sourceId, oldSource);
    expect(state.manuscript.effectiveHistories[id], oldHistory);
    var preview = await library.previewSourceRefresh(id);
    expect(preview.bodyChanged, true);
    final before = jsonDecode(jsonEncode(state.projectDocument()));
    expect(state.projectDocument(), before); // Preview is not a mutation.
    final kept = await library.applySourceRefresh(
      preview,
      fields: {},
      replaceBody: false,
    );
    expect(File(kept.recoveryPath!).existsSync(), true);
    expect(state.current.source!.sourceId, oldSource);
    expect(state.manuscript.effectiveHistories[id], oldHistory);
    expect(state.production.settings(id)['title'], '手工书名');
    expect(state.current.path, isNot(path));
    expect(File(state.current.path).readAsStringSync(), contains('正文乙'));
    expect(
      (await library.saveProject('$root/kept.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/kept.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openChapters(id).read(0)).nodes.first.title,
      '第一章 旧编辑',
    );
    expect(library.books.value.length, 2);

    preview = await library.previewSourceRefresh(id);
    final result = await library.applySourceRefresh(
      preview,
      fields: {},
      replaceBody: true,
    );
    expect(state.current.source!.sourceId, isNot(oldSource));
    expect(state.manuscript.effectiveHistories.containsKey(id), false);
    expect((await library.openChapters(id).read(0)).nodes.map((n) => n.title), [
      '第一章 新章节',
      '第二章 续篇',
    ]);
    expect(state.production.settings(id)['title'], '手工书名');
    expect(state.production.settings(id)['author'], '');
    expect(state.production.settings(id)['description'], '手工简介');
    await expectLater(
      library.applySourceRefresh(preview, fields: {}, replaceBody: true),
      throwsFormatException,
    );
    expect(
      (await library.saveProject('$root/refreshed.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/refreshed.easypub.json')).succeeded,
      true,
    );
    expect(File(library.sourceRecoveryPath(id)!).existsSync(), true);
    final conversion = library.openConversion();
    try {
      final p = await conversion.preview(
        ConversionRequest(
          books: [id],
          directory: root,
          format: 'EPUB',
          runChecks: false,
        ),
      );
      expect(p.previewed, true);
      final files = await conversion.commit(p, acknowledgeWarnings: true);
      expect(files.single.phase, 'complete', reason: files.single.detail);
      final checked = await Process.run(
        Platform.environment['EASYPUB_TEST_PYTHON']!,
        [
          '-X',
          'utf8',
          '-c',
          // 每章一个文件（V36，OUT-081）：按文件名顺序读全部正文文件（body、body-0001…与阅读顺序一致）。
          r"import re,sys,zipfile,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); docs=[E.fromstring(z.read(p)) for p in sorted((p for p in z.namelist() if re.fullmatch(r'EPUB/body(-\d{4})?\.xhtml',p)),key=lambda p:int(p[10:14]) if '-' in p else -1)]; n={'h':'http://www.w3.org/1999/xhtml'}; assert [x.text for b in docs for x in b.findall('.//h:p',n)]==['　　新的正文甲','　　新的正文乙']; assert [x.text for b in docs for x in b.findall('.//h:h1',n)]==['第一章 新章节','第二章 续篇']",
          files.single.path,
        ],
      );
      expect(checked.exitCode, 0, reason: checked.stderr.toString());
    } finally {
      conversion.dispose();
    }
    expect((await library.openProject(result.recoveryPath!)).succeeded, true);
    expect(library.books.value.length, 1);
    expect(
      (await library.openChapters(id).read(0)).nodes.first.title,
      '第一章 旧编辑',
    );
    expect(File(path).readAsStringSync(), changed);
  });

  test(
    'refresh rejects changed proposals and failed recovery before publication',
    () async {
      final (state, library, root) = await fixture();
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final id = state.currentId, path = state.current.path;
      await File(path).writeAsString('第一章 新稿\n新正文');
      final p = await library.previewSourceRefresh(id);
      final before = jsonDecode(jsonEncode(state.projectDocument()));
      await File(path).writeAsString('第一章 又变\n再次变化');
      await expectLater(
        library.applySourceRefresh(p, fields: {}, replaceBody: true),
        throwsFormatException,
      );
      expect(state.projectDocument(), before);
      final q = await library.previewSourceRefresh(id);
      final info = library.openBookInformation(id);
      await info.apply(await info.preview({'author': '新手工作者'}));
      info.dispose();
      await expectLater(
        library.applySourceRefresh(q, fields: {}, replaceBody: true),
        throwsFormatException,
      );
      final r = await library.previewSourceRefresh(id);
      final frozen = jsonDecode(jsonEncode(state.projectDocument()));
      await File('$root/settings/source-recovery').writeAsString('阻止目录创建');
      await expectLater(
        library.applySourceRefresh(r, fields: {}, replaceBody: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(state.projectDocument(), frozen);
      expect(state.projectBusy, false);
    },
  );

  test('EPUB metadata-only refresh explicitly adopts selected fields and preserves chapters', () async {
    final root = (await Directory('../artifacts').createTemp('refresh-epub80-'))
        .absolute
        .path;
    final path = '$root/book.epub';
    Future<void> write(String title, String author) async {
      final r = await Process.run(
        Platform.environment['EASYPUB_TEST_PYTHON']!,
        [
          '-X',
          'utf8',
          '-c',
          "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('mimetype','application/epub+zip'); z.writestr('META-INF/container.xml','<container><rootfiles><rootfile full-path=\"book.opf\"/></rootfiles></container>'); z.writestr('book.opf','<package><metadata><title>'+sys.argv[2]+'</title><creator>'+sys.argv[3]+'</creator><language>zh-CN</language></metadata><manifest><item id=\"c\" href=\"text.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"c\"/></spine></package>'); z.writestr('text.xhtml','<html><body><h1>第一章 开始</h1><p>正文保持</p></body></html>'); z.close()",
          path,
          title,
          author,
        ],
      );
      expect(r.exitCode, 0, reason: r.stderr.toString());
    }

    await write('原书名', '原作者');
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    expect((await library.importFiles([path])).single.succeeded, true);
    final id = state.currentId;
    final info = library.openBookInformation(id);
    await info.apply(await info.preview({'author': ''}));
    info.dispose();
    final chapters = library.openChapters(id);
    var tree = await chapters.read(0);
    await chapters.confirm(
      await chapters.preview(
        tree,
        RenameChapter(tree.nodes.first.id, '第一章 手工编辑'),
      ),
    );
    final history = jsonDecode(
      jsonEncode(state.manuscript.effectiveHistories[id]),
    );
    await write('新来源书名', '新来源作者');
    final p = await library.previewSourceRefresh(id);
    expect(p.bodyChanged, false);
    expect(p.incoming['title'], '新来源书名');
    await library.applySourceRefresh(p, fields: {'title'}, replaceBody: false);
    expect(state.production.settings(id)['title'], '新来源书名');
    expect(state.production.settings(id)['author'], '');
    expect(
      state.production.settings(id)['metadata_origins']['author']['source'],
      'manual',
    );
    expect(state.manuscript.effectiveHistories[id], history);
    expect(
      (await library.saveProject('$root/metadata.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/metadata.easypub.json')).succeeded,
      true,
    );
    tree = await library.openChapters(id).read(0);
    expect(tree.nodes.first.title, '第一章 手工编辑');
    expect(state.production.settings(id)['title'], '新来源书名');
  });
}
