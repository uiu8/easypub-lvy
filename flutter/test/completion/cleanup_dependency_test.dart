import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cleanup history cannot invalidate dependent chapter edits', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final dir = await Directory.systemTemp.createTemp(
      'easypub-cleanup-dependency-',
    );
    final state = PrototypeState(settingsDirectory: '${dir.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    final source = File('${dir.path}/source.txt');
    const original = '第一章 开始\n这里是正文  \n第二章 后续\n正文结束\n';
    await source.writeAsString(original);
    expect((await library.importFiles([source.path])).single.succeeded, true);
    final id = library.books.value.single.id;
    final cleanup = library.openCleanup(id);
    addTearDown(cleanup.dispose);
    final plan = await cleanup.preview(
      jsonEncode({
        'kind': 'cleanup',
        'pipeline': [
          {'kind': 'trim_trailing_spaces'},
        ],
      }),
    );
    await cleanup.apply(plan);
    final chapters = library.openChapters(id);
    final page = await chapters.read(0);
    await chapters.rename(page, page.nodes.first.id, '第一章 已改名');
    Future<List<String>> firstBody() async {
      final tree = await chapters.read(0);
      return (await chapters.body(tree, tree.nodes.first.id, 0)).lines;
    }

    // V17（CLEAN-103）起：撤销 / 重做清理把章节修改换算到新文本上，改名保留。
    await cleanup.undo();
    expect(state.cleanup.historyStatus[id], contains('1 处章节修改已换算'));
    expect((await chapters.read(0)).nodes.first.title, '第一章 已改名');
    expect(await firstBody(), ['这里是正文  ']);
    await cleanup.redo();
    // 撤销再重做清理是往返：退回原来的章节步骤，不留换算步骤。
    expect((state.manuscript.effectiveHistories[id]!['history'] as List).length, 2);
    expect(state.manuscript.effectiveHistories[id]!['cursor'], 1);
    expect((await chapters.read(0)).nodes.first.title, '第一章 已改名');
    expect(await firstBody(), ['这里是正文']);
    // 变更记录页撤销清理同样换算。
    final history = library.openChangeHistory();
    final cleanupRecord = history
        .records(id)
        .firstWhere((record) => record.domain == '文本清理' && record.canUndo);
    await history.undo(history.detail(cleanupRecord));
    expect((await chapters.read(0)).nodes.first.title, '第一章 已改名');
    expect(await firstBody(), ['这里是正文  ']);
    await cleanup.redo();
    expect(await firstBody(), ['这里是正文']);

    final project = '${dir.path}/protected.easypub.json';
    expect(await state.saveProjectOutcome(project), true);
    final reopened = PrototypeState(settingsDirectory: '${dir.path}/reopen');
    addTearDown(reopened.dispose);
    expect(await reopened.openProjectOutcome(project), true);
    expect(
      ((await reopened.manuscript.effectiveTree(id, 0))['nodes'] as List).first['title'],
      '第一章 已改名',
    );

    // Undo dependent edits first; cleanup can then move without losing history.
    expect(await state.manuscript.editEffectiveDraft(id, {'op': 'undo'}), true);
    await cleanup.undo();
    expect((await chapters.read(0)).nodes.first.title, '第一章 开始');
    await cleanup.redo();
    expect(await state.manuscript.editEffectiveDraft(id, {'op': 'redo'}), true);
    expect((await chapters.read(0)).nodes.first.title, '第一章 已改名');
    expect(await source.readAsString(), original);
  });
}
