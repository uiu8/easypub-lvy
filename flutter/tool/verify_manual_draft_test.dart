import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'real DLL draft undo survives project reopen and batch commit',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File('build/windows/x64/runner/Release/easypub_bridge.dll')
              .absolute
              .path,
        ),
      );
      final run = await Directory(
        '../artifacts/r4-manual-draft/${DateTime.now().microsecondsSinceEpoch}',
      ).create(recursive: true);
      final source = File('${run.absolute.path}/原稿.txt');
      const original = '第一章 甲\r\n正文甲\n第二章 乙\r正文乙';
      await source.writeAsString(original);
      final state = PrototypeState();
      final reopened = PrototypeState();
      try {
        await state.importBookOutcome(source.path);
        final imported = state.current.source!;
        Map<String, dynamic>? draft;
        Future<void> command(Map<String, dynamic> action) async {
          draft = jsonDecode(
            await api.editManualDraft(
              sourceId: imported.sourceId,
              revision: imported.revision,
              draftJson: draft == null ? '' : jsonEncode(draft),
              commandJson: jsonEncode(action),
            ),
          ) as Map<String, dynamic>;
        }

        for (final edit in [(1, '第一章 新甲'), (3, '第二章 新乙')]) {
          await command({
            'op': 'put',
            'action': {
              'kind': 'rename_title',
              'source_line': edit.$1,
              'title': edit.$2,
            },
          });
        }
        await command({'op': 'undo'});
        expect(draft!['cursor'], 1);
        state.manuscript.manualEditDrafts[state.currentId] = draft!;
        final project = '${run.absolute.path}/草稿.easypub.json';
        await state.saveProjectOutcome(project);
        expect(await File(project).exists(), true, reason: state.projectStatus);
        await reopened.openProjectOutcome(project);
        expect(
          reopened.current.source,
          isNotNull,
          reason: reopened.projectStatus,
        );
        draft = reopened.manuscript.manualEditDrafts[reopened.currentId];
        expect(draft, isNotNull);
        expect(draft!['cursor'], 1);
        expect(draft!['history'], hasLength(3));
        await command({'op': 'redo'});
        await command({
          'op': 'put',
          'action': {
            'kind': 'set_volume',
            'source_line': 1,
            'volume_title': '第一卷 起',
          },
        });
        await command({'op': 'remove', 'source_line': 1, 'kind': 'set_volume'});
        await command({'op': 'undo'});
        final request = jsonEncode({
          'kind': 'manual_batch',
          'actions': draft!['history'][draft!['cursor']],
        });
        final plan = jsonDecode(
          await api.previewRepairPlanText(
            sourceId: imported.sourceId,
            revision: imported.revision,
            selectedJson: request,
          ),
        );
        expect(plan['actions'], hasLength(3));
        final output = File('${run.absolute.path}/批量副本.txt');
        final receipt = jsonDecode(
          await api.commitRepairOutputText(
            sourceId: imported.sourceId,
            revision: imported.revision,
            sourcePath: source.path,
            outputPath: output.path,
            selectedJson: request,
            planId: plan['plan_id'] as String,
            confirmed: true,
          ),
        );
        expect(receipt['committed'], true);
        expect(
          await output.readAsString(),
          '第一卷 起\r\n第一章 新甲\r\n正文甲\n第二章 新乙\r正文乙',
        );
        expect(await source.readAsString(), original);
        expect(
          await File('${receipt['transaction_dir']}/source-backup.bin')
              .readAsBytes(),
          await source.readAsBytes(),
        );
        final broken = jsonDecode(await File(project).readAsString());
        broken['books'][0]['manual_draft']['history'][2][0]['source_line'] = 2;
        final bad = File('${run.absolute.path}/坏草稿.easypub.json');
        await bad.writeAsString(jsonEncode(broken));
        await reopened.openProjectOutcome(bad.path);
        expect(reopened.projectPath, project);
        expect(reopened.manuscript.manualEditDrafts[reopened.currentId]!['cursor'], 1);
        await File('../docs/evidence/r4-manual-draft.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'passed': true,
            'verified_at': DateTime.now().toIso8601String(),
            'receipt': receipt,
            'checks': [
              'undo history survives project reopen',
              'redo after reopen',
              'batch exact mixed-newline output',
              'same-line rename and volume insertion coexist',
              'selective removal and undo restore only selected action',
              'source and backup unchanged',
              'invalid historical action rejected without replacing active project',
            ],
          }),
        );
      } finally {
        state.dispose();
        reopened.dispose();
      }
    },
  );
}
