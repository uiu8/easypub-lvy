import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';

import 'library_removal_test.dart' as fixtures;

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test('checkpoint-only draft survives frontend selection, reopen, undo and EPUB export', () async {
    final (state, library, root) = await fixtures.fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = library.books.value.first.id;
    library.selectBook(id);
    final originalFile = File(library.books.value.first.path);
    final original = await originalFile.readAsBytes();
    var chapter = library.openChapters(id);
    var page = await chapter.read(0);
    final nodeId = page.nodes.first.id;
    expect(page.editBudget!.replayBytes, 0);
    expect(page.editBudget!.nextActionBytes, original.length);

    await chapter.confirm(
      await chapter.preview(page, RenameChapter(nodeId, '第一章 检查点保留标题')),
    );
    final editedBudget = (await chapter.read(0)).editBudget!;
    expect(editedBudget.replayBytes, original.length);
    expect(editedBudget.canAppend, true);
    final changes = library.openChangeHistory();
    final originalRecord = changes
        .records(id)
        .firstWhere((r) => r.domain == '章节');
    final originalFields = changes
        .detail(originalRecord)
        .fields
        .map((f) => [f.label, f.before, f.after])
        .toList();
    final source = state.shelf.books.firstWhere((b) => b.id == id).source!;
    final result = jsonDecode(
      await api.editEffectiveDraft(
        sourceId: source.sourceId,
        revision: source.revision,
        baseJson: jsonEncode(state.manuscript.effectiveBase(id)),
        draftJson: jsonEncode(state.manuscript.effectiveHistories[id]),
        commandJson: jsonEncode({
          'op': 'checkpoint',
          'directory': '$root/checkpoints',
        }),
      ),
    ) as Map;
    expect(result['matches_current'], true);
    state.change(
      () => state.manuscript.effectiveHistories[id] = (result['history'] as Map)
          .cast<String, dynamic>(),
    );
    expect(state.manuscript.effectiveSelection(id)!['actions'], isEmpty);
    expect(state.manuscript.effectiveSelection(id)!['checkpoint'], isNotNull);
    final sameRecord = changes
        .records(id)
        .firstWhere((r) => r.id == originalRecord.id);
    expect(
      changes
          .detail(sameRecord)
          .fields
          .map((f) => [f.label, f.before, f.after])
          .toList(),
      originalFields,
    );
    final originalTrees = await changes.chapterTrees(
      changes.detail(sameRecord),
      0,
    );
    expect(originalTrees.before.first.title, '第一章 开始');
    expect(originalTrees.after.first.title, '第一章 检查点保留标题');

    final checkpointBudget = (await chapter.read(0)).editBudget!;
    expect(checkpointBudget.replayBytes, 0);
    expect(checkpointBudget.nextActionBytes, editedBudget.nextActionBytes);

    expect((await chapter.read(0)).nodes.first.title, '第一章 检查点保留标题');
    expect(
      (await library.saveProject('$root/book.easypub.json')).succeeded,
      true,
    );
    final saved =
        jsonDecode(await File('$root/book.easypub.json').readAsString()) as Map;
    final savedBook = (saved['books'] as List).firstWhere(
      (b) => b['path'] == originalFile.path,
    );
    final savedHistory = savedBook['effective_history'] as Map;
    final checkpoint =
        savedHistory['history'][savedHistory['cursor']]['request']['checkpoint']
            as Map;
    final directory = checkpoint['directory'] as String;
    expect(directory, startsWith('easypub-edit-assets-'));
    expect(directory.contains('/'), false);
    expect(directory.contains(r'\'), false);
    final digest = checkpoint['reference']['digest'];
    final savedBlob = File('$root/$directory/$digest.json');
    final copiedBytes = await savedBlob.readAsBytes();
    expect(
      copiedBytes,
      await File('$root/checkpoints/$digest.json').readAsBytes(),
    );
    // Move the project and its sidecar; retain the original cache out of the way.
    // All paths are fixture-owned and no user directory is removed.
    await Directory('$root/checkpoints').rename('$root/retained-checkpoints');
    await Directory('$root/moved').create();
    await File('$root/book.easypub.json').copy('$root/moved/book.easypub.json');
    final beforeFailedOpen = jsonEncode(state.projectDocument());
    expect(
      (await library.openProject('$root/moved/book.easypub.json')).succeeded,
      false,
    );
    expect(jsonEncode(state.projectDocument()), beforeFailedOpen);
    await Directory('$root/$directory').rename('$root/moved/$directory');
    final movedBlob = File('$root/moved/$directory/$digest.json');
    await movedBlob.writeAsString('damaged fixture');
    expect(
      (await library.openProject('$root/moved/book.easypub.json')).succeeded,
      false,
    );
    expect(jsonEncode(state.projectDocument()), beforeFailedOpen);
    await movedBlob.writeAsBytes(copiedBytes);

    expect(
      (await library.openProject('$root/moved/book.easypub.json')).succeeded,
      true,
    );
    chapter = library.openChapters(id);
    page = await chapter.read(0);
    expect(page.nodes.first.title, '第一章 检查点保留标题');
    expect(page.nodes.first.id, nodeId);
    await chapter.history(page, undo: true);
    page = await chapter.read(0);
    expect(page.nodes.first.title, '第一章 检查点保留标题');
    await chapter.history(page, undo: true);
    page = await chapter.read(0);
    expect(page.nodes.first.title, '第一章 开始');
    expect(
      (await library.saveProject('$root/redo.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/redo.easypub.json')).succeeded,
      true,
    );
    chapter = library.openChapters(id);
    page = await chapter.read(0);
    await chapter.history(page, undo: false);
    await chapter.history(await chapter.read(0), undo: false);
    final conversion = library.openConversion();
    addTearDown(conversion.dispose);
    final preview = await conversion.preview(
      ConversionRequest(
        books: [id],
        directory: root,
        format: 'EPUB',
        runChecks: false,
      ),
    );
    expect(preview.previewed, true);
    final output = (await conversion.commit(
      preview,
      acknowledgeWarnings: true,
    )).single;
    expect(output.phase, 'complete', reason: output.detail);
    expect(await File(output.path).exists(), true);
    final inspected = await Process.run(
      Platform.environment['EASYPUB_TEST_PYTHON']!,
      [
        '-X',
        'utf8',
        '-c',
        "import sys,zipfile,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); ns={'h':'http://www.w3.org/1999/xhtml'}; body=E.fromstring(z.read('EPUB/body.xhtml')); nav=E.fromstring(z.read('EPUB/nav.xhtml')); assert [e.text for e in body.findall('.//h:p',ns)]==['　　'+v for v in sys.argv[2].splitlines()[1:]]; assert body.find('.//h:h1',ns).text==sys.argv[3]; assert nav.find('.//h:a',ns).text==sys.argv[3]",
        output.path,
        utf8.decode(original),
        '第一章 检查点保留标题',
      ],
    );
    expect(inspected.exitCode, 0, reason: inspected.stderr.toString());

    await File('$root/export-path.txt').writeAsString(output.path);
    await chapter.confirm(
      await chapter.preview(
        await chapter.read(0),
        RenameChapter(nodeId, '第一章 检查点后继续编辑'),
      ),
    );
    expect((await chapter.read(0)).nodes.first.title, '第一章 检查点后继续编辑');
    expect(await originalFile.readAsBytes(), original);
  });
}
