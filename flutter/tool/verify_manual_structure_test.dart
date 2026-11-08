import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('named volume draft uses structure through history project and commit', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r4-manual-structure/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${dir.absolute.path}/原稿.txt');
    const text = '启程\n卷首甲\n第一章 甲\n甲文\n归来\n卷首乙\n第二章 乙\n乙文';
    await file.writeAsString(text);
    final state = PrototypeState(), reopened = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final source = state.current.source!, id = state.currentId;
      final structure = <String, dynamic>{
        'source_id': source.sourceId,
        'revision': source.revision,
        'overrides': [
          for (final line in [1, 5])
            {
              'source_line': line,
              'role': 'volume',
              'depth': 0,
              'include_toc': true,
            },
        ],
      };
      state.manuscript.structures[id] = structure;
      Map<String, dynamic>? draft;
      Future<Map<String, dynamic>> edit(
        Map<String, dynamic> cmd, {
        Map<String, dynamic>? context,
      }) async => (jsonDecode(
        await api.editManualDraft(
          sourceId: source.sourceId,
          revision: source.revision,
          draftJson: draft == null ? '' : jsonEncode(draft),
          commandJson: jsonEncode({...cmd, 'structure': context ?? structure}),
        ),
      ) as Map).cast<String, dynamic>();
      draft = await edit({
        'op': 'put',
        'action': {'kind': 'move_volume', 'source_line': 5, 'before_line': 1},
      });
      final moved = jsonEncode(draft);
      draft = await edit({'op': 'undo'});
      state.manuscript.manualEditDrafts[id] = draft;
      final project = '${dir.absolute.path}/项目.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(project);
      expect(reopened.manuscript.manualEditDrafts[id], draft);
      expect(reopened.manuscript.structures[id], structure);
      draft = reopened.manuscript.manualEditDrafts[id];
      draft = await edit({'op': 'redo'});
      expect(jsonEncode(draft), moved);
      final actions = draft['history'][draft['cursor']];
      final request = <String, dynamic>{
        'kind': 'manual_batch',
        'actions': actions,
        'structure': structure,
      };
      Future<Map> preview(Map request) async => jsonDecode(
        await api.previewRepairPlanText(
          sourceId: source.sourceId,
          revision: source.revision,
          selectedJson: jsonEncode(request),
        ),
      ) as Map;
      final plan = await preview(request);
      final changed = jsonDecode(jsonEncode(structure)) as Map<String, dynamic>;
      changed['overrides'][0]['include_toc'] = false;
      final changedRequest = {...request, 'structure': changed};
      expect(
        (await preview(changedRequest))['plan_id'],
        isNot(plan['plan_id']),
      );
      final rejected = '${dir.absolute.path}/过期.txt';
      await expectLater(
        api.commitRepairOutputText(
          sourceId: source.sourceId,
          revision: source.revision,
          sourcePath: file.path,
          outputPath: rejected,
          selectedJson: jsonEncode(changedRequest),
          planId: plan['plan_id'] as String,
          confirmed: true,
        ),
        throwsA(anything),
      );
      expect(File(rejected).existsSync(), false);
      final bad = {...structure, 'source_id': '0' * 64};
      await expectLater(
        edit({'op': 'inspect'}, context: bad),
        throwsA(anything),
      );
      await expectLater(
        edit({
          'op': 'put',
          'action': {'kind': 'merge_previous', 'source_line': 7},
        }),
        throwsA(anything),
      );
      expect(jsonEncode(draft), moved);
      final output = File('${dir.absolute.path}/副本.txt');
      final receipt = jsonDecode(
        await api.commitRepairOutputText(
          sourceId: source.sourceId,
          revision: source.revision,
          sourcePath: file.path,
          outputPath: output.path,
          selectedJson: jsonEncode(request),
          planId: plan['plan_id'] as String,
          confirmed: true,
        ),
      ) as Map;
      expect(receipt['committed'], true);
      expect(
        await output.readAsString(),
        '归来\n卷首乙\n第二章 乙\n乙文\n启程\n卷首甲\n第一章 甲\n甲文\n',
      );
      expect(await file.readAsString(), text);
      expect(
        await File('${receipt['transaction_dir']}/source-backup.bin')
            .readAsBytes(),
        await file.readAsBytes(),
      );
      final tampered = jsonDecode(await File(project).readAsString()) as Map;
      tampered['books'][0]['structure']['overrides'].removeLast();
      final invalid = File('${dir.absolute.path}/错误结构.easypub.json');
      await invalid.writeAsString(jsonEncode(tampered));
      await reopened.openProjectOutcome(invalid.path);
      expect(reopened.projectPath, project);
      expect(reopened.manuscript.structures[id], structure);
      await File('../docs/evidence/r4-manual-structure.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'receipt': receipt,
          'checks': [
            'named volumes with introductions move as complete spans',
            'undo project reopen redo preserves history',
            'changed structure invalidates plan consent',
            'cross volume merge and foreign structure rejected',
            'invalid historical structure rejects project atomically',
            'exact output and source backup preserved',
          ],
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
