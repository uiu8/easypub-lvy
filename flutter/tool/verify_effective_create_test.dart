import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefix and volume-body boundaries persist and preserve original text', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final run = await Directory(
      '../artifacts/r4-effective-create/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${run.absolute.path}/原稿.txt');
    const raw = '卷首\r\n说明\n篇题\r正文';
    await file.writeAsString(raw);
    final state = PrototypeState(), reopened = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final id = state.currentId, source = state.current.source!;
      final prefix = await state.manuscript.effectiveTree(
        id,
        0,
        previewNodeId: r'$prefix',
      );
      expect(prefix['nodes'], isEmpty);
      expect(prefix['body_preview']['rows'][0]['source_line'], 1);
      expect(
        await state.manuscript.editEffectiveDraft(id, {
          'op': 'append',
          'action': {
            'kind': 'create_boundary',
            'entry_id': null,
            'line_offset': 1,
            'role': 'volume',
            'depth': 0,
            'include_toc': true,
          },
        }),
        true,
      );
      final volume = (await state.manuscript.effectiveTree(id, 0))['nodes'][0]['entry_id'];
      expect(
        await state.manuscript.editEffectiveDraft(id, {
          'op': 'append',
          'action': {
            'kind': 'create_boundary',
            'entry_id': volume,
            'line_offset': 2,
            'role': 'chapter',
            'depth': 1,
            'include_toc': true,
          },
        }),
        true,
      );
      final tree = await state.manuscript.effectiveTree(id, 0);
      final chapter = tree['nodes'][1]['entry_id'];
      expect(tree['nodes'][1]['parent_id'], volume);
      final structureRequest = {
        'kind': 'publication',
        ...state.manuscript.effectiveBase(id),
        'post_edits': state.manuscript.effectiveSelection(id),
      };
      final preview = jsonDecode(
        await api.previewRepairPlanText(
          sourceId: source.sourceId,
          revision: source.revision,
          selectedJson: jsonEncode(structureRequest),
        ),
      );
      expect(preview['text_changed'], false);
      final saved = jsonEncode(state.manuscript.effectiveHistories[id]);
      await state.manuscript.editEffectiveDraft(id, {'op': 'undo'});
      final project = '${run.absolute.path}/项目.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(project);
      await reopened.manuscript.editEffectiveDraft(id, {'op': 'redo'});
      expect(jsonEncode(reopened.manuscript.effectiveHistories[id]), saved);
      expect((await reopened.manuscript.effectiveTree(id, 0))['nodes'], tree['nodes']);
      await reopened.manuscript.editEffectiveDraft(id, {
        'op': 'append',
        'action': {'kind': 'rename', 'entry_id': chapter, 'title': '新章名'},
      });
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
      expect(await output.readAsString(), '卷首\r\n说明\n新章名\r正文');
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
      await File('../docs/evidence/r4-effective-create.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'receipt': receipt,
          'checks': [
            'prefix preview',
            'create volume and child chapter without changing text',
            'undo save reopen redo stable identities',
            'rename and exact mixed-ending output',
            'resource hash and backup agreement',
          ],
          'not_verified': [
            'real desktop interaction',
            'all cross-volume matrix cases',
          ],
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
