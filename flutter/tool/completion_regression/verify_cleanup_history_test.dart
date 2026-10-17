import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import '../legacy_state_helpers.dart';

void main() {
  test('cleanup history survives projects and disabled cleanup stays out of output', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(Platform.environment['EASYPUB_TEST_DLL'] ?? 'build/windows/x64/runner/Release/easypub_bridge.dll')
            .absolute
            .path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r5-cleanup-history/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${dir.absolute.path}/原稿.txt');
    const original = '第一章 甲\r\n正文  \n尾行';
    await file.writeAsString(original);
    final state = PrototypeState(), restored = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final id = state.currentId;
      final settings = <String, dynamic>{
        'kind': 'cleanup',
        'pipeline': [
          {'kind': 'trim_trailing_spaces'},
        ],
      };
      await state.cleanup.saveSettings(id, settings);
      await state.cleanup.saveSettings(id, settings);
      expect(state.cleanup.histories[id]!['history'], hasLength(2));
      expect(await state.cleanup.editSettings(id, {'op': 'disable'}), true);
      expect(state.cleanup.drafts[id], isNull);
      expect(await state.cleanup.editSettings(id, {'op': 'undo'}), true);
      final target = '${dir.absolute.path}/含清理历史.easypub.json';
      await state.saveProjectOutcome(target);
      expect(await File(target).exists(), true, reason: state.projectStatus);
      await restored.openProjectOutcome(target);
      expect(
        restored.cleanup.histories[restored.currentId],
        state.cleanup.histories[id],
      );
      expect(
        restored.cleanup.drafts[restored.currentId]!['pipeline'],
        settings['pipeline'],
      );
      expect(
        await restored.cleanup.editSettings(restored.currentId, {'op': 'redo'}),
        true,
      );
      expect(restored.cleanup.drafts[restored.currentId], isNull);
      final disabledProject = '${dir.absolute.path}/已停用.easypub.json';
      await restored.saveProjectOutcome(disabledProject);
      final disabledDoc = jsonDecode(
        await File(disabledProject).readAsString(),
      );
      expect(disabledDoc['books'][0].containsKey('cleanup'), false);
      expect(
        disabledDoc['books'][0]['cleanup_history']['history'],
        hasLength(3),
      );
      await restored.openProjectOutcome(disabledProject);
      expect(restored.cleanup.drafts[restored.currentId], isNull);
      final source = restored.current.source!;
      final request = {
        'kind': 'publication',
        'manual': {
          'kind': 'manual_batch',
          'actions': [
            {'kind': 'rename_title', 'source_line': 1, 'title': '第一章 新名'},
          ],
        },
        if (restored.cleanup.drafts[restored.currentId] != null)
          'cleanup': restored.cleanup.drafts[restored.currentId],
      };
      final plan = jsonDecode(
        await api.previewRepairPlanText(
          sourceId: source.sourceId,
          revision: source.revision,
          selectedJson: jsonEncode(request),
        ),
      );
      final output = '${dir.absolute.path}/停用后输出.txt';
      await api.commitRepairOutputText(
        sourceId: source.sourceId,
        revision: source.revision,
        sourcePath: file.path,
        outputPath: output,
        selectedJson: jsonEncode(request),
        planId: plan['plan_id'],
        confirmed: true,
      );
      expect(await File(output).readAsString(), '第一章 新名\r\n正文  \n尾行');
      expect(await restored.cleanup.editSettings(id, {'op': 'undo'}), true);
      await restored.cleanup.saveSettings(id, {
        'kind': 'cleanup',
        'pipeline': [
          {'kind': 'literal_replace', 'find': '正文', 'replace': '段落'},
        ],
      });
      expect(await restored.cleanup.editSettings(id, {'op': 'redo'}), false);
      final before = jsonEncode(restored.projectDocument());
      final corrupt = jsonDecode(await File(target).readAsString());
      // Damage an inactive history entry, leaving the current cleanup unchanged.
      corrupt['books'][0]['cleanup_history']['history'][2] = {
        'kind': 'cleanup',
        'rules': ['trim_trailing_spaces'],
        'start_line': 999,
      };
      final bad = '${dir.absolute.path}/损坏历史.easypub.json';
      await File(bad).writeAsString(jsonEncode(corrupt));
      await restored.openProjectOutcome(bad);
      expect(jsonEncode(restored.projectDocument()), before);
      expect(restored.projectStatus, contains('不受支持'));
      // Inconsistent mirrors must also be rejected before saving any project.
      final inconsistent = jsonDecode(before);
      inconsistent['books'][0].remove('cleanup');
      final refused = '${dir.absolute.path}/不一致.easypub.json';
      final refusal = jsonDecode(
        await api.saveProjectText(
          path: refused,
          payload: jsonEncode(inconsistent),
        ),
      );
      expect(refusal['error'], 'InvalidRule');
      expect(refusal['operation'], 'project_schema');
      expect(await File(refused).exists(), false);
      expect(await file.readAsString(), original);
      await File('../artifacts/completion-implementation-20261004/regression/r5-cleanup-history.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'project': target,
          'checks': [
            'same preview does not duplicate history',
            'disable and undo',
            'project reopen preserves redo',
            'disabled state persisted',
            'disabled rule absent from exact output',
            'new branch truncates redo',
            'inactive corrupt history rejected without replacing current library',
            'inconsistent current settings rejected before save',
            'original unchanged',
          ],
          'limits': [
            '51 saved setting states; 1 MiB per book history',
            'individual unsaved rule edits remain dialog-local',
          ],
        }),
      );
    } finally {
      state.dispose();
      restored.dispose();
    }
  });
}
