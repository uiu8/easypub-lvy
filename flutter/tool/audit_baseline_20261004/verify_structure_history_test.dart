import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('structural history roundtrip and branching through actual DLL', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(Platform.environment['EASYPUB_TEST_DLL'] ?? '../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r4-structure-history/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${dir.absolute.path}/原稿.txt');
    const text = '序篇\n第一章 初见\n正文\n第二章 再会\n正文二';
    await file.writeAsString(text);
    final state = PrototypeState();
    final reopened = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final id = state.currentId;
      final source = state.current.source!;
      Future<Map<String, dynamic>> edit(
        Map<String, dynamic>? history,
        Map<String, dynamic> command,
      ) async => (jsonDecode(
        await api.editStructureDraft(
          sourceId: source.sourceId,
          revision: source.revision,
          draftJson: history == null ? '' : jsonEncode(history),
          commandJson: jsonEncode(command),
        ),
      ) as Map).cast<String, dynamic>();
      void accept(PrototypeState s, Map<String, dynamic> history) {
        s.change(() {
          s.manuscript.structureHistories[id] = history;
          s.manuscript.structures[id] =
              (history['history'][history['cursor']] as Map)
                  .cast<String, dynamic>();
        });
      }

      final base = await edit(null, {'op': 'inspect'});
      final report = jsonDecode(
        await api.chapterStructureText(
          sourceId: source.sourceId,
          revision: source.revision,
          settingsJson: '',
          changeJson: jsonEncode({
            'source_line': 1,
            'role': 'volume',
            'depth': 0,
            'include_toc': false,
          }),
          offset: 0,
        ),
      ) as Map;
      final history = await edit(base, {
        'op': 'set',
        'structure': report['settings'],
      });
      expect(history['cursor'], 1);
      accept(state, history);
      final project = '${dir.absolute.path}/structure.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(project);
      expect(reopened.manuscript.structureHistories[id], history);
      final undo = await edit(reopened.manuscript.structureHistories[id], {'op': 'undo'});
      accept(reopened, undo);
      expect(reopened.manuscript.structures[id]!['overrides'], isEmpty);
      final undone = '${dir.absolute.path}/undone.easypub.json';
      await reopened.saveProjectOutcome(undone);
      expect(File(undone).existsSync(), true);
      await state.openProjectOutcome(undone);
      expect(state.manuscript.structureHistories[id]!['cursor'], 0);
      final redo = await edit(state.manuscript.structureHistories[id], {'op': 'redo'});
      accept(state, redo);
      expect(state.manuscript.structures[id], report['settings']);
      final invalid = jsonDecode(jsonEncode(report['settings'])) as Map;
      invalid['overrides'][0]['depth'] = 3;
      await expectLater(
        edit(redo, {'op': 'set', 'structure': invalid}),
        throwsA(anything),
      );
      expect(state.manuscript.structureHistories[id], redo);
      final alternate = jsonDecode(jsonEncode(report['settings'])) as Map;
      alternate['overrides'][0]['include_toc'] = true;
      final branch = await edit(await edit(redo, {'op': 'undo'}), {
        'op': 'set',
        'structure': alternate,
      });
      await expectLater(edit(branch, {'op': 'redo'}), throwsA(anything));
      final badProject = state.projectDocument();
      (badProject['books'] as List)[0]['structure'] = base['history'][0];
      final bad = jsonDecode(
        await api.saveProjectText(
          path: '${dir.absolute.path}/invalid.easypub.json',
          payload: jsonEncode(badProject),
        ),
      ) as Map;
      expect(bad.containsKey('error'), true);
      expect(
        File('${dir.absolute.path}/invalid.easypub.json').existsSync(),
        false,
      );
      // Projects predating structural history continue to load their existing structure.
      final legacy = state.projectDocument();
      (legacy['books'] as List)[0].remove('structure_history');
      final oldPath = '${dir.absolute.path}/legacy.easypub.json';
      final saved = jsonDecode(
        await api.saveProjectText(path: oldPath, payload: jsonEncode(legacy)),
      ) as Map;
      expect(saved.containsKey('error'), false);
      await reopened.openProjectOutcome(oldPath);
      expect(reopened.manuscript.structureHistories, isEmpty);
      expect(reopened.manuscript.structures[id], report['settings']);
      expect(await file.readAsString(), text);
      await File('../artifacts/audit-20261004/baseline/evidence/r4-structure-history.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'actual_dll': true,
          'project_history_roundtrip': true,
          'undo_state_saved_and_redone_after_reopen': true,
          'invalid_level_rejected': true,
          'branch_discards_redo': true,
          'history_current_mismatch_rejected': true,
          'legacy_structure_without_history_loads': true,
          'source_unchanged': true,
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
