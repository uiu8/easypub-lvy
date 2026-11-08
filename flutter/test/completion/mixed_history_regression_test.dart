import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/application/change_history_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(
    () => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test('B5 混合规则、章节、清理、修复撤销后保留重做并可重开', () async {
    final root = (await Directory('../artifacts').createTemp('b5-history-'))
        .absolute;
    final source = File('${root.path}/原稿.txt')
      ..writeAsStringSync('第一章 起\n正文  \n第一节课在三楼的二年级混编班。\n正文\n第三章 终\n尾文  \n');
    final original = source.readAsBytesSync();
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    expect((await library.importFiles([source.path])).single.succeeded, true);
    final id = state.currentId;
    // 旧项目保留的误识别结构，必须经过显式修复。
    state.change(() => state.manuscript.structures.remove(id));
    final chapters = library.openChapters(id);
    final rules = library.openRuleCatalog(id);
    final cleanup = library.openCleanup(id);
    addTearDown(rules.dispose);
    addTearDown(cleanup.dispose);
    final history = library.openChangeHistory();
    final redo = history as RedoChangeHistoryService;
    Future<void> move(String domain, bool undo) async {
      final record = history
          .records(id)
          .firstWhere(
            (r) => r.domain == domain && (undo ? r.canUndo : r.canRedo),
          );
      final detail = history.detail(record);
      if (undo) {
        await history.undo(detail);
      } else {
        await redo.redo(detail);
      }
    }

    Future<List<List<String>>> bodies() async {
      final page = await chapters.read(0);
      return [
        for (final node in page.nodes)
          (await chapters.body(page, node.id, 0)).lines,
      ];
    }

    final baselineBodies = await bodies();
    final baseline = (await chapters.read(0)).nodes
        .map((n) => n.title)
        .toList();
    final options = await chapters.repairs(await chapters.read(0));
    final prose = options.changes.singleWhere(
      (c) => c.id.startsWith('prose-heading:'),
    );
    final repair = await chapters.previewRepairs(options, {prose.id});
    await chapters.confirm(repair.preview);
    final toggle = await rules.previewToggles([
      {'id': 'check.number_gap', 'enabled': false},
    ]);
    await rules.applyToggles(toggle['plan_id'] as String);
    final tree = await chapters.read(0);
    await chapters.rename(tree, tree.nodes.last.id, '第三章 已编辑');
    await cleanup.apply(
      await cleanup.preview(
        jsonEncode({
          'kind': 'cleanup',
          'pipeline': [
            {'kind': 'trim_trailing_spaces'},
          ],
        }),
      ),
    );
    final finalTitles = (await chapters.read(0)).nodes
        .map((n) => n.title)
        .toList();
    expect(finalTitles, ['第一章 起', '第三章 已编辑']);
    final cleanedBodies = await bodies();
    expect(
      cleanedBodies.expand((lines) => lines).any((line) => line.endsWith('  ')),
      false,
    );
    await move('文本清理', true);
    await move('章节', true); // 改名
    await move('规则开关', true);
    await move('章节', true); // 修复
    expect((await chapters.read(0)).nodes.map((n) => n.title), baseline);
    expect(await bodies(), baselineBodies);
    expect(
      (await library.saveProject('${root.path}/撤销后.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('${root.path}/撤销后.easypub.json')).succeeded,
      true,
    );
    await move('章节', false);
    await move('规则开关', false);
    await move('章节', false);
    await move('文本清理', false);
    expect((await chapters.read(0)).nodes.map((n) => n.title), finalTitles);
    expect(await bodies(), cleanedBodies);
    expect(source.readAsBytesSync(), original);
  });
}
