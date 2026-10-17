import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/application/change_history_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old structure/manual histories undo and redo with cleanup and dependent chapters, reopen and export', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('history-dependencies85-')).absolute.path;
    final file = File('$root/旧项目.txt')
      ..writeAsStringSync('序篇\n第一章 开始\n正文  \n第二章 后续\n末行\n');
    final original = await file.readAsBytes();
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    expect((await library.importFiles([file.path])).single.succeeded, true);
    final id = state.currentId, source = state.current.source!;
    final structure = jsonDecode(
      await api.chapterStructureText(
        sourceId: source.sourceId,
        revision: source.revision,
        settingsJson: '',
        changeJson: jsonEncode({
          'source_line': 1,
          'role': 'volume',
          'depth': 0,
          'include_toc': true,
        }),
        offset: 0,
      ),
    ) as Map;
    final structureHistory = (jsonDecode(
      await api.editStructureDraft(
        sourceId: source.sourceId,
        revision: source.revision,
        draftJson: '',
        commandJson: jsonEncode({
          'op': 'set',
          'structure': structure['settings'],
        }),
      ),
    ) as Map).cast<String, dynamic>();
    final manual = (jsonDecode(
      await api.editManualDraft(
        sourceId: source.sourceId,
        revision: source.revision,
        draftJson: '',
        commandJson: jsonEncode({
          'op': 'put',
          'structure': structure['settings'],
          'action': {
            'kind': 'rename_title',
            'source_line': 2,
            'title': '第一章 旧版改名',
          },
        }),
      ),
    ) as Map).cast<String, dynamic>();
    state.change(() {
      state.manuscript.structureHistories[id] = structureHistory;
      state.manuscript.structures[id] = (structure['settings'] as Map)
          .cast<String, dynamic>();
      state.manuscript.manualEditDrafts[id] = manual;
    });
    final cleanup = library.openCleanup(id);
    addTearDown(cleanup.dispose);
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
    final chapters = library.openChapters(id);
    final tree = await chapters.read(0);
    await chapters.rename(tree, tree.nodes.last.id, '第二章 新版编辑');
    final history = library.openChangeHistory();
    final redo = history as RedoChangeHistoryService;
    ChangeDetail detail(String domain, {bool undo = true}) => history.detail(
      history
          .records(id)
          .firstWhere(
            (r) => r.domain == domain && (undo ? r.canUndo : r.canRedo),
          ),
    );
    final info = library.openBookInformation(id);
    await info.apply(await info.preview({'author': '历史恢复作者'}));
    info.dispose();
    await history.undo(detail('制作'));
    expect(state.production.settings(id)['author'], '');
    await redo.redo(detail('制作', undo: false));
    expect(state.production.settings(id)['author'], '历史恢复作者');
    final frozen = jsonEncode(state.projectDocument());
    for (final domain in ['结构', '人工编辑']) {
      await expectLater(history.undo(detail(domain)), throwsFormatException);
      expect(jsonEncode(state.projectDocument()), frozen);
    }
    // V17（CLEAN-103）起，撤销 / 重做清理会把章节修改换算到新文本上，不再拒绝。
    await history.undo(detail('文本清理'));
    expect((await chapters.read(0)).nodes.last.title, '第二章 新版编辑');
    expect(state.cleanup.historyStatus[id], contains('1 处章节修改已换算'));
    await redo.redo(detail('文本清理', undo: false));
    expect((await chapters.read(0)).nodes.last.title, '第二章 新版编辑');
    final stale = detail('人工编辑');
    await history.undo(detail('章节'));
    await expectLater(history.undo(stale), throwsFormatException);
    await history.undo(detail('文本清理'));
    await history.undo(detail('人工编辑'));
    await history.undo(detail('结构'));
    expect((await chapters.read(0)).nodes.map((n) => n.title), [
      '第一章 开始',
      '第二章 后续',
    ]);
    expect(
      (await library.saveProject('$root/undone.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/undone.easypub.json')).succeeded,
      true,
    );
    final beforeRedo = jsonEncode(state.projectDocument());
    await expectLater(
      chapters.history(await chapters.read(0), undo: false),
      throwsFormatException,
    );
    expect(jsonEncode(state.projectDocument()), beforeRedo);
    await expectLater(
      redo.redo(detail('章节', undo: false)),
      throwsFormatException,
    );
    expect(jsonEncode(state.projectDocument()), beforeRedo);
    await redo.redo(detail('结构', undo: false));
    await redo.redo(detail('人工编辑', undo: false));
    await redo.redo(detail('文本清理', undo: false));
    await File('$root/base-comparison.json').writeAsString(
      jsonEncode({
        'expected':
            (state.manuscript.effectiveHistories[id]!['history']
                as List)[1]['base'],
        'actual': state.manuscript.effectiveBase(id),
      }),
    );
    await redo.redo(detail('章节', undo: false));
    expect((await chapters.read(0)).nodes.map((n) => n.title), [
      '序篇',
      '第一章 旧版改名',
      '第二章 新版编辑',
    ]);
    expect(
      (await library.saveProject('$root/restored.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/restored.easypub.json')).succeeded,
      true,
    );
    final conversion = library.openConversion();
    addTearDown(conversion.dispose);
    final p = await conversion.preview(
      ConversionRequest(
        books: [id],
        directory: root,
        format: 'EPUB',
        runChecks: false,
      ),
    );
    expect(p.previewed, true);
    final output = (await conversion.commit(
      p,
      acknowledgeWarnings: true,
    )).single;
    expect(output.phase, 'complete', reason: output.detail);
    final parsed = await Process.run(
      Platform.environment['EASYPUB_TEST_PYTHON']!,
      [
        '-X',
        'utf8',
        '-c',
        // 每章一个文件（V36，OUT-081）：合并全部正文文件的文字。
        r"import re,sys,zipfile,xml.etree.ElementTree as E;z=zipfile.ZipFile(sys.argv[1]);t=''.join(''.join(E.fromstring(z.read(n)).itertext()) for n in z.namelist() if re.fullmatch(r'EPUB/body(-\d{4})?\.xhtml',n));assert '第一章 旧版改名' in t and '第二章 新版编辑' in t and '正文  ' not in t",
        output.path,
      ],
    );
    expect(parsed.exitCode, 0, reason: parsed.stderr.toString());
    expect(await file.readAsBytes(), original);
  });
}
