import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('inserted volumes move and survive history and exact output', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final run = await Directory(
      '../artifacts/r4-effective-volume/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${run.absolute.path}/原稿.txt');
    const raw = '第一章 甲\n甲文\n第二章 乙\n乙文\n第三章 丙\n丙文\n';
    await file.writeAsString(raw);
    final state = PrototypeState(), reopened = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final id = state.currentId, source = state.current.source!;
      final base = await state.manuscript.effectiveTree(id, 0);
      final first = base['nodes'][0]['entry_id'],
          third = base['nodes'][2]['entry_id'];
      await state.manuscript.editEffectiveDraft(id, {
        'op': 'append',
        'action': {'kind': 'insert_volume', 'entry_id': first, 'title': '起程'},
      });
      final firstVolume = (await state.manuscript.effectiveTree(
        id,
        0,
      ))['nodes'][0]['entry_id'];
      await state.manuscript.editEffectiveDraft(id, {
        'op': 'append',
        'action': {'kind': 'insert_volume', 'entry_id': third, 'title': '归来'},
      });
      final secondVolume = (await state.manuscript.effectiveTree(
        id,
        0,
      ))['nodes'][3]['entry_id'];
      await state.manuscript.editEffectiveDraft(id, {
        'op': 'append',
        'action': {
          'kind': 'move_subtree',
          'entry_id': secondVolume,
          'before_id': firstVolume,
        },
      });
      final moved = await state.manuscript.effectiveTree(id, 0);
      expect(moved['nodes'][1]['entry_id'], third);
      expect(moved['nodes'][1]['parent_id'], secondVolume);
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
        '归来\n第三章 丙\n丙文\n起程\n第一章 甲\n甲文\n第二章 乙\n乙文\n',
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
      await File('../docs/evidence/r4-effective-volume.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'receipt': receipt,
          'checks': [
            'insert unnumbered volumes',
            'reparent ungrouped chapters',
            'move created volume with bodies',
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
