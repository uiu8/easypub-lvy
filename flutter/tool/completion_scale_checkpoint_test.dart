import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/chapter_service.dart';

import '../test/completion/library_removal_test.dart' as fixtures;

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test('8 MiB real session warns before action 64 and checkpoint restores editing', () async {
    final clock = Stopwatch()..start();
    final (state, library, root) = await fixtures.fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final body = Uint8List(8 * 1024 * 1024)..fillRange(0, 8 * 1024 * 1024, 97);
    final text = '第一章 开始\n${utf8.decode(body)}\n';
    final file = File('$root/大书.txt');
    await file.writeAsString(text);
    expect((await library.importFiles([file.path])).single.succeeded, true);
    final id = library.books.value.firstWhere((b) => b.path == file.path).id;
    library.selectBook(id);
    final chapter = library.openChapters(id);
    final initial = await chapter.read(0);
    final nodeId = initial.nodes.first.id;
    await state.manuscript.editEffectiveDraft(id, {
      'op': 'append_batch',
      'actions': List.generate(
        63,
        (_) => {'kind': 'rename', 'entry_id': nodeId, 'title': '第一章 修改'},
      ),
    });
    final page = await chapter.read(0);
    final bytes = utf8.encode(text).length;
    expect((chapter as ChapterCheckpointSession).pendingEditActions, 63);
    expect(page.editBudget!.replayBytes, bytes * 63);
    expect(page.editBudget!.nearLimit, true);
    expect(page.editBudget!.canAppend, false);
    final previous = jsonEncode(state.manuscript.effectiveHistories[id]);
    await expectLater(
      chapter.preview(page, RenameChapter(nodeId, '第一章 超限')),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('正文较大'),
        ),
      ),
    );
    expect(jsonEncode(state.manuscript.effectiveHistories[id]), previous);
    await chapter.confirm(
      await (chapter as ChapterCheckpointSession).previewCheckpoint(page),
    );
    final restored = await chapter.read(0);
    expect(restored.editBudget!.replayBytes, 0);
    expect(restored.editBudget!.canAppend, true);
    expect(restored.nodes.first.title, '第一章 修改');
    await chapter.confirm(
      await chapter.preview(restored, RenameChapter(nodeId, '第一章 继续')),
    );
    expect((await chapter.read(0)).nodes.first.title, '第一章 继续');
    expect(
      (await library.saveProject('$root/large.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/large.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openChapters(id).read(0)).nodes.first.title,
      '第一章 继续',
    );
    expect(await file.readAsString(), text);
    stdout.writeln(
      'scale66 frontend bytes=$bytes actions=63 blocked=64 continued=1 reopen=true elapsed_ms=${clock.elapsedMilliseconds}',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
