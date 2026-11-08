import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/prototype/project_io.dart' as projects;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_removal_test.dart' show fixture;

void main() {
  test('resident recovery retains edited manuscript after external change, moves and exports correctly', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final (state, library, root) = await fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    final path = state.current.path;
    final original = await File(path).readAsBytes();
    final other = state.shelf.books.firstWhere(
      (book) => !book.isDemo && book.id != id,
    );
    final otherBytes = await File(other.path).readAsBytes();
    final info = library.openBookInformation(id);
    await info.apply(
      await info.preview({
        'author': '',
        'title': '手工书名',
        'description': '保留手工简介',
      }),
    );
    info.dispose();
    final chapters = library.openChapters(id);
    final tree = await chapters.read(0);
    await chapters.confirm(
      await chapters.preview(
        tree,
        RenameChapter(tree.nodes.first.id, '第一章 保留编辑'),
      ),
    );

    final baseline = jsonDecode(jsonEncode(state.production.settings(id)));
    final preview = await state.production.previewChanges({
      id: {
        'op': 'source_metadata',
        'fields': {'title': '采用来源书名'},
      },
    });
    expect(state.production.settings(id), baseline);
    expect(await state.production.confirm(preview), true);
    var values = state.production.settings(id);
    expect(values['title'], '采用来源书名');
    expect(values['author'], '');
    expect(values['description'], '保留手工简介');
    expect(values['metadata_origins']['author']['source'], 'manual');
    expect(values['metadata_origins']['title']['source'], 'imported');
    expect(
      await state.production.confirm(
        await state.production.previewChanges({
          id: {'op': 'undo'},
        }),
      ),
      true,
    );
    expect(state.production.settings(id), baseline);
    expect(
      await state.production.confirm(
        await state.production.previewChanges({
          id: {'op': 'redo'},
        }),
      ),
      true,
    );
    final oldProject = '$root/old.easypub.json';
    expect((await library.saveProject(oldProject)).succeeded, true);
    final oldProjectBytes = await File(oldProject).readAsBytes();
    final savedIdentity = state.savedProjectIdentity;
    await File(path).writeAsString('第九章 外部替换\n这是新的文件内容\n');
    await File(other.path).delete();
    final projectBefore = jsonDecode(jsonEncode(state.projectDocument()));
    final recovery = '$root/recovery.easypub.json';
    await projects.saveRecoveryProject(recovery, state.projectDocument());
    expect(state.projectDocument(), projectBefore);
    expect(state.savedProjectIdentity, savedIdentity);
    expect(state.projectPath, oldProject);
    expect(await File(oldProject).readAsBytes(), oldProjectBytes);
    expect(await File(path).readAsString(), '第九章 外部替换\n这是新的文件内容\n');
    expect(await File(other.path).exists(), false);

    final moved = Directory('$root/moved');
    await moved.create();
    await File(recovery).rename('${moved.path}/recovery.easypub.json');
    await Directory('$recovery.sources')
        .rename('${moved.path}/recovery.easypub.json.sources');
    final opened = await library.openProject(
      '${moved.path}/recovery.easypub.json',
    );
    expect(opened.succeeded, true, reason: opened.message);
    expect(library.books.value, hasLength(2));
    expect(state.currentId, id);
    expect(await File(state.current.path).readAsBytes(), original);
    expect(
      await File(state.shelf.books.firstWhere((b) => b.id == other.id).path)
          .readAsBytes(),
      otherBytes,
    );
    values = state.production.settings(id);
    expect(values['title'], '采用来源书名');
    expect(values['metadata_origins']['author']['source'], 'manual');
    final restored = library.openChapters(id);
    expect((await restored.read(0)).nodes.first.title, '第一章 保留编辑');
    expect(
      await state.production.confirm(
        await state.production.previewChanges({
          id: {'op': 'undo'},
        }),
      ),
      true,
    );
    expect(state.production.settings(id)['title'], '手工书名');
    expect(
      await state.production.confirm(
        await state.production.previewChanges({
          id: {'op': 'redo'},
        }),
      ),
      true,
    );

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
      final outputs = await conversion.commit(p, acknowledgeWarnings: true);
      expect(outputs.single.phase, 'complete', reason: outputs.single.detail);
      final check = await Process.run(
        Platform.environment['EASYPUB_TEST_PYTHON']!,
        [
          '-X',
          'utf8',
          '-c',
          "import sys,zipfile,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); b=E.fromstring(z.read('EPUB/body.xhtml')); n={'h':'http://www.w3.org/1999/xhtml'}; assert [x.text for x in b.findall('.//h:h1',n)]==['第一章 保留编辑']; assert [x.text for x in b.findall('.//h:p',n)]==['　　正文乙']; assert '这是新的文件内容' not in ''.join(b.itertext())",
          outputs.single.path,
        ],
      );
      expect(check.exitCode, 0, reason: check.stderr.toString());
    } finally {
      conversion.dispose();
    }
    expect(await File(path).readAsString(), '第九章 外部替换\n这是新的文件内容\n');
    expect(await File(oldProject).readAsBytes(), oldProjectBytes);
  });
}
