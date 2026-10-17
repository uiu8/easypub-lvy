import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('merge roots and child siblings preserves body ownership and history', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final run = await Directory(
      '../artifacts/r4-effective-merge/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${run.absolute.path}/原稿.txt');
    const raw = '甲标题\n甲正文\n甲子题\n甲子文\n乙标题\n乙正文\n乙子题\n乙子文\n';
    await file.writeAsString(raw);
    final state = PrototypeState(), reopened = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final id = state.currentId, source = state.current.source!;
      state.manuscript.structures[id] = {
        'source_id': source.sourceId,
        'revision': source.revision,
        'overrides': [
          {
            'source_line': 1,
            'role': 'chapter',
            'depth': 0,
            'include_toc': true,
          },
          {
            'source_line': 3,
            'role': 'section',
            'depth': 1,
            'include_toc': true,
          },
          {
            'source_line': 5,
            'role': 'chapter',
            'depth': 0,
            'include_toc': true,
          },
          {
            'source_line': 7,
            'role': 'section',
            'depth': 1,
            'include_toc': true,
          },
        ],
      };
      final base = await state.manuscript.effectiveTree(id, 0);
      final ids = (base['nodes'] as List).map((n) => n['entry_id']).toList();
      await state.manuscript.editEffectiveDraft(id, {
        'op': 'append',
        'action': {'kind': 'merge_subtree_previous', 'entry_id': ids[2]},
      });
      final parent = await state.manuscript.effectiveTree(id, 0, previewNodeId: ids[0]);
      expect(parent['body_preview']['rows'].map((r) => r['text']).toList(), [
        '甲正文',
        '乙正文',
      ]);
      expect(parent['nodes'][2]['parent_id'], ids[0]);
      await state.manuscript.editEffectiveDraft(id, {
        'op': 'append',
        'action': {'kind': 'merge_subtree_previous', 'entry_id': ids[3]},
      });
      final moved = await state.manuscript.effectiveTree(id, 0);
      expect(moved['nodes'], hasLength(2));
      expect(moved['nodes'][1]['entry_id'], ids[1]);
      final complete = jsonEncode(state.manuscript.effectiveHistories[id]);
      await state.manuscript.editEffectiveDraft(id, {'op': 'undo'});
      final project = '${run.absolute.path}/项目.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(project);
      await reopened.manuscript.editEffectiveDraft(id, {'op': 'redo'});
      expect(jsonEncode(reopened.manuscript.effectiveHistories[id]), complete);
      expect((await reopened.manuscript.effectiveTree(id, 0))['nodes'], moved['nodes']);
      final request = {
        'kind': 'publication',
        ...reopened.manuscript.effectiveBase(id),
        'post_edits': reopened.manuscript.effectiveSelection(id),
      };
      final plan = jsonDecode(
        await api.previewRepairPlanText(
          sourceId: source.sourceId,
          revision: source.revision,
          selectedJson: jsonEncode(request),
        ),
      );
      final resource = await reopened.production.publicationResources(id);
      final output = File('${run.absolute.path}/副本.txt');
      final receipt = jsonDecode(
        await api.commitRepairOutputText(
          sourceId: source.sourceId,
          revision: source.revision,
          sourcePath: file.path,
          outputPath: output.path,
          selectedJson: jsonEncode(request),
          planId: plan['plan_id'],
          confirmed: true,
        ),
      );
      expect(receipt['committed'], true);
      expect(await output.readAsString(), '甲标题\n甲正文\n乙正文\n甲子题\n甲子文\n乙子文\n');
      final audit = jsonDecode(
        await File('${receipt['transaction_dir']}/edit-evidence.json')
            .readAsString(),
      );
      expect(audit['text_utf8_sha256'], resource['manifest']['text_sha256']);
      expect(await file.readAsString(), raw);
      expect(
        await File('${receipt['transaction_dir']}/source-backup.bin')
            .readAsBytes(),
        await file.readAsBytes(),
      );
      await File('../docs/evidence/r4-effective-merge.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'dll_path': File(
            Platform.environment['EASYPUB_TEST_DLL'] ??
                '../target/release/easypub_bridge.dll',
          ).absolute.path,
          'verified_at': DateTime.now().toIso8601String(),
          'receipt': receipt,
          'checks': [
            'merge root siblings retains child identity',
            'direct bodies stay with parent rather than last child',
            'second merge joins child siblings without lost body',
            'undo save reopen redo',
            'exact TXT and resource hash',
            'original and backup intact',
          ],
          'not_verified': [
            'all cross-volume matrix cases',
            'real desktop interaction',
          ],
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
