import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mixed role subtrees move with descendants and persist', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final run = await Directory(
      '../artifacts/r4-effective-subtree/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${run.absolute.path}/原稿.txt');
    const raw = '第一章 甲\n甲文\n节甲\n节正文\n第二章 乙\n乙文\n前言项\n前置正文';
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
            'source_line': 3,
            'role': 'section',
            'depth': 1,
            'include_toc': false,
          },
          {'source_line': 7, 'role': 'front', 'depth': 0, 'include_toc': true},
        ],
      };
      final base = await state.manuscript.effectiveTree(id, 0);
      final ids = (base['nodes'] as List).map((n) => n['entry_id']).toList();
      await state.manuscript.editEffectiveDraft(id, {
        'op': 'append',
        'action': {
          'kind': 'move_subtree',
          'entry_id': ids[0],
          'before_id': ids[3],
        },
      });
      final withChild = await state.manuscript.effectiveTree(id, 0);
      expect(withChild['nodes'][2]['parent_id'], ids[0]);
      await state.manuscript.editEffectiveDraft(id, {
        'op': 'append',
        'action': {
          'kind': 'move_subtree',
          'entry_id': ids[1],
          'before_id': ids[2],
        },
      });
      await state.manuscript.editEffectiveDraft(id, {
        'op': 'append',
        'action': {
          'kind': 'move_subtree',
          'entry_id': ids[3],
          'before_id': ids[2],
        },
      });
      final moved = await state.manuscript.effectiveTree(id, 0);
      expect(moved['nodes'][0]['entry_id'], ids[1]);
      expect(moved['nodes'][0]['depth'], 0);
      expect(moved['nodes'][0]['include_toc'], false);
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
      expect(
        await output.readAsString(),
        '节甲\n节正文\n前言项\n前置正文\n第二章 乙\n乙文\n第一章 甲\n甲文\n',
      );
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
      await File('../docs/evidence/r4-effective-subtree.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'receipt': receipt,
          'checks': [
            'chapter subtree retains section child',
            'section changes destination depth without changing identity',
            'front node moves with unterminated body and line mapping',
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
