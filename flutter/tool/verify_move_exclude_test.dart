import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'actual move and exclusion survive undo, reopen, and audit removed content',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File('build/windows/x64/runner/Release/easypub_bridge.dll')
              .absolute
              .path,
        ),
      );
      final dir = await Directory(
        '../artifacts/r4-move-exclude/${DateTime.now().microsecondsSinceEpoch}',
      ).create(recursive: true);
      final source = File('${dir.absolute.path}/原稿.txt');
      const body = '第一章 甲\n甲文\n第二章 乙\n乙文\n尾注';
      await source.writeAsString(body);
      final state = PrototypeState(), reopened = PrototypeState();
      try {
        await state.importBookOutcome(source.path);
        final imported = state.current.source!;
        Map<String, dynamic>? draft;
        Future<void> command(Map<String, dynamic> command) async {
          draft = jsonDecode(
            await api.editManualDraft(
              sourceId: imported.sourceId,
              revision: imported.revision,
              draftJson: draft == null ? '' : jsonEncode(draft),
              commandJson: jsonEncode(command),
            ),
          ) as Map<String, dynamic>;
        }

        await command({
          'op': 'put',
          'action': {
            'kind': 'move_chapter',
            'source_line': 3,
            'before_line': 1,
          },
        });
        await command({
          'op': 'put',
          'action': {'kind': 'exclude_lines', 'source_line': 5, 'end_line': 5},
        });
        await command({'op': 'undo'});
        expect((draft!['history'][draft!['cursor']] as List).length, 1);
        state.manuscript.manualEditDrafts[state.currentId] = draft!;
        final project = '${dir.absolute.path}/移动草稿.easypub.json';
        await state.saveProjectOutcome(project);
        expect(await File(project).exists(), true, reason: state.projectStatus);
        await reopened.openProjectOutcome(project);
        draft = reopened.manuscript.manualEditDrafts[reopened.currentId];
        expect(draft, isNotNull, reason: reopened.projectStatus);
        await command({'op': 'redo'});
        final frozen = jsonEncode(draft);
        await expectLater(
          command({
            'op': 'put',
            'action': {
              'kind': 'rename_title',
              'source_line': 5,
              'title': '第二章 冲突',
            },
          }),
          throwsA(anything),
        );
        expect(jsonEncode(draft), frozen);
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
        expect(plan['actions'], hasLength(2));
        expect(plan['actions'][0]['evidence'], contains('移动完整章节区段'));
        expect(plan['actions'][1]['evidence'], contains('源行 5 至 5'));
        final output = File('${dir.absolute.path}/移动排除副本.txt');
        Future<String> commit(bool confirmed) => api.commitRepairOutputText(
          sourceId: imported.sourceId,
          revision: imported.revision,
          sourcePath: source.path,
          outputPath: output.path,
          selectedJson: request,
          planId: plan['plan_id'],
          confirmed: confirmed,
        );
        await expectLater(commit(false), throwsA(anything));
        expect(await output.exists(), false);
        final receipt = jsonDecode(await commit(true));
        expect(receipt['source_unchanged'], true);
        expect(await output.readAsString(), '第二章 乙\n乙文\n第一章 甲\n甲文\n');
        expect(receipt['recheck']['chapter_count'], 2);
        expect(await source.readAsString(), body);
        expect(
          await File('${receipt['transaction_dir']}/source-backup.bin')
              .readAsBytes(),
          await source.readAsBytes(),
        );
        final evidence = jsonDecode(
          await File('${receipt['transaction_dir']}/edit-evidence.json')
              .readAsString(),
        );
        expect(evidence['plan_id'], plan['plan_id']);
        expect(evidence['changes'][0]['before'], '尾注');
        expect(evidence['changes'][0]['after'], '');
        await expectLater(commit(true), throwsA(anything));
        await File('../docs/evidence/r4-move-exclude.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'passed': true,
            'verified_at': DateTime.now().toIso8601String(),
            'receipt': receipt,
            'checks': [
              'move retains chapter body exactly once',
              'explicit exclusion range retained in evidence',
              'undo and redo survive project reopen',
              'conflicting action leaves draft unchanged',
              'exact chapter order and retained body',
              'removed source text evidence persisted before publish',
              'source backup byte equality',
              'confirmation required',
              'existing output rejected',
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
