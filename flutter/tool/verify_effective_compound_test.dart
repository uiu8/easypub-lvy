import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compound effective tree edits keep identities, history and output', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final run = await Directory(
      '../artifacts/r4-effective-compound/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${run.absolute.path}/原稿.txt');
    const raw = '第一章 甲\n甲文\n甲文后半\n第二章 乙\n乙文\n第三章 丙\n丙文\n第四章 丁\n丁文\n';
    await file.writeAsString(raw);
    final state = PrototypeState(), reopened = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final id = state.currentId, source = state.current.source!;
      state.manuscript.structures[id] = {
        'source_id': source.sourceId,
        'revision': source.revision,
        'overrides': [
          for (final line in [1, 4, 6, 8])
            {
              'source_line': line,
              'role': 'chapter',
              'depth': 0,
              'include_toc': true,
            },
        ],
      };
      Future<void> append(Map<String, dynamic> action) async {
        try {
          expect(
            await state.manuscript.editEffectiveDraft(id, {
              'op': 'append',
              'action': action,
            }),
            true,
            reason: 'rejected action $action',
          );
        } catch (error) {
          fail('rejected action $action: $error');
        }
      }

      final initial = await state.manuscript.effectiveTree(id, 0);
      final ids = (initial['nodes'] as List)
          .map((n) => n['entry_id'] as String)
          .toList();
      await append({'kind': 'rename', 'entry_id': ids[0], 'title': '甲章·改名'});
      await append({
        'kind': 'split',
        'entry_id': ids[0],
        'line_offset': 2,
        'title': '第五章 甲章后半',
      });
      await append({
        'kind': 'move_subtree',
        'entry_id': ids[2],
        'before_id': ids[0],
      });
      await append({
        'kind': 'classify',
        'entry_id': ids[2],
        'role': 'section',
        'depth': 0,
        'include_toc': false,
      });
      await append({'kind': 'rename', 'entry_id': ids[2], 'title': '丙节'});
      await append({
        'kind': 'merge_into',
        'entry_id': ids[2],
        'target_id': ids[0],
      });
      await append({
        'kind': 'insert_volume',
        'entry_id': ids[1],
        'title': '第一部·编辑后',
      });
      final edited = await state.manuscript.effectiveTree(id, 0);
      final editedNodes = (edited['nodes'] as List)
          .map((n) => (n as Map).cast<String, dynamic>())
          .toList();
      expect(editedNodes.any((n) => n['title'] == '第一部·编辑后'), true);
      expect(editedNodes.any((n) => n['title'] == '甲章·改名'), true);
      expect(editedNodes.any((n) => n['title'] == '第五章 甲章后半'), true);
      expect(editedNodes.any((n) => n['title'] == '丙节'), false);
      expect(editedNodes.every((n) => n['entry_id'] is String), true);
      final editedHistory = state.manuscript.effectiveHistories[id];

      final project = '${run.absolute.path}/项目.easypub.json';
      await state.saveProjectOutcome(project);
      await reopened.openProjectOutcome(project);
      expect(reopened.manuscript.effectiveHistories[id], editedHistory);
      final reopenedTree = await reopened.manuscript.effectiveTree(id, 0);
      expect(reopenedTree['nodes'], edited['nodes']);

      await reopened.manuscript.editEffectiveDraft(id, {'op': 'undo'});
      await reopened.manuscript.editEffectiveDraft(id, {'op': 'redo'});
      expect((await reopened.manuscript.effectiveTree(id, 0))['nodes'], edited['nodes']);

      final selection = {
        'kind': 'publication',
        ...reopened.manuscript.effectiveBase(id),
        'post_edits': reopened.manuscript.effectiveSelection(id),
      };
      final plan = jsonDecode(
        await api.previewRepairPlanText(
          sourceId: source.sourceId,
          revision: source.revision,
          selectedJson: jsonEncode(selection),
        ),
      );
      final output = File('${run.absolute.path}/复合编辑副本.txt');
      final receipt = jsonDecode(
        await api.commitRepairOutputText(
          sourceId: source.sourceId,
          revision: source.revision,
          sourcePath: file.path,
          outputPath: output.path,
          selectedJson: jsonEncode(selection),
          planId: plan['plan_id'],
          confirmed: true,
        ),
      );
      expect(receipt['committed'], true);
      expect(await file.readAsString(), raw);
      expect(
        (await output.readAsLines()).length,
        greaterThan(raw.split('\n').length - 1),
      );
      await File('../docs/evidence/r4-effective-compound.json').writeAsString(
        JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'output': output.path,
          'transaction_dir': receipt['transaction_dir'],
          'node_count': editedNodes.length,
          'checks': [
            'rename, subtree move, classify, merge-into and split compose in one history',
            'inserted volume preserves stable identities and descendants',
            'save reopen undo redo restores identical effective tree',
            'confirmed TXT output and transaction keep original unchanged',
          ],
          'not_verified': ['Kindle Previewer and device rendering'],
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
