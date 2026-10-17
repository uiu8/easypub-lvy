import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('effective edit history survives project and preserves stale recipes', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final run = await Directory(
      '../artifacts/r4-effective-history/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${run.absolute.path}/原稿.txt');
    const raw = '001 起\n甲文\n002 续\n乙文\n';
    await file.writeAsString(raw);
    final state = PrototypeState(), reopened = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final source = state.current.source!, id = state.currentId;
      final cleanup = <String, dynamic>{
        'kind': 'cleanup',
        'pipeline': [
          {'kind': 'chapter_numbers', 'style': 'chinese', 'bare_titles': true},
        ],
      };
      state.cleanup.drafts[id] = cleanup;
      final base = jsonDecode(
        await api.effectiveStructureText(
          sourceId: source.sourceId,
          revision: source.revision,
          settingsJson: '',
          selectedJson: jsonEncode({'kind': 'publication', 'cleanup': cleanup}),
          offset: 0,
        ),
      );
      final first = base['nodes'][0]['entry_id'],
          second = base['nodes'][1]['entry_id'];
      expect(
        await state.manuscript.editEffectiveDraft(id, {
          'op': 'append',
          'action': {'kind': 'move', 'entry_id': second, 'before_id': first},
        }),
        true,
      );
      expect(
        await state.manuscript.editEffectiveDraft(id, {
          'op': 'append',
          'action': {'kind': 'rename', 'entry_id': second, 'title': '新续章'},
        }),
        true,
      );
      expect(
        await state.manuscript.editEffectiveDraft(id, {
          'op': 'append',
          'action': {
            'kind': 'classify',
            'entry_id': second,
            'role': 'section',
            'depth': 0,
            'include_toc': false,
          },
        }),
        true,
      );
      final classified = await state.manuscript.effectiveTree(id, 0);
      expect(classified['nodes'][0]['role'], 'section');
      expect(classified['nodes'][0]['include_toc'], false);
      expect(classified['nodes'][0]['entry_id'], second);
      final complete = jsonEncode(state.manuscript.effectiveHistories[id]);
      await state.manuscript.editEffectiveDraft(id, {'op': 'undo'});
      final project = '${run.absolute.path}/项目.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(project);
      expect(reopened.manuscript.effectiveHistories[id], state.manuscript.effectiveHistories[id]);
      await reopened.manuscript.editEffectiveDraft(id, {'op': 'redo'});
      expect(jsonEncode(reopened.manuscript.effectiveHistories[id]), complete);
      final restoredTree = await reopened.manuscript.effectiveTree(id, 0);
      expect(restoredTree['nodes'], classified['nodes']);
      final resource = await reopened.production.publicationResources(id);
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
      final output = File('${run.absolute.path}/副本.txt');
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
      expect(await output.readAsString(), '新续章\n乙文\n第一章 起\n甲文\n');
      final audit = jsonDecode(
        await File('${receipt['transaction_dir']}/edit-evidence.json')
            .readAsString(),
      );
      expect(resource['manifest']['text_sha256'], audit['text_utf8_sha256']);
      reopened.cleanup.drafts.remove(id);
      expect(await reopened.manuscript.editEffectiveDraft(id, {'op': 'inspect'}), false);
      await expectLater(reopened.production.publicationResources(id), throwsA(anything));
      final stale = '${run.absolute.path}/保留旧历史.easypub.json';
      await reopened.saveProjectOutcome(stale);
      expect(File(stale).existsSync(), true, reason: reopened.projectStatus);
      await state.openProjectOutcome(stale);
      expect(await state.manuscript.editEffectiveDraft(id, {'op': 'inspect'}), false);
      expect(await state.manuscript.editEffectiveDraft(id, {'op': 'clear'}), true);
      expect(state.manuscript.effectiveSelection(id), isNull);
      expect(await state.manuscript.editEffectiveDraft(id, {'op': 'undo'}), false);
      expect(state.manuscript.effectiveSelection(id), isNotNull);
      state.cleanup.drafts[id] = cleanup;
      expect(await state.manuscript.editEffectiveDraft(id, {'op': 'inspect'}), true);
      final bad = state.projectDocument();
      bad['books'][0]['effective_history']['history'][0]['request']['base_id'] =
          '0' * 64;
      final invalid = '${run.absolute.path}/无效历史.easypub.json';
      final rejection = jsonDecode(
        await api.saveProjectText(path: invalid, payload: jsonEncode(bad)),
      );
      expect(rejection.containsKey('error'), true);
      expect(File(invalid).existsSync(), false);
      expect(await file.readAsString(), raw);
      await File('../docs/evidence/r4-effective-history.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'receipt': receipt,
          'checks': [
            'undo save reopen redo',
            'classify after move and rename keeps node identity and exact tree after reopen',
            'output and resource text match',
            'stale recipes preserved but not applied',
            'clear undo retains old recipe',
            'restored cleanup revalidates history',
            'invalid inactive history rejected',
            'source unchanged',
          ],
          'not_verified': ['effective tree editing UI'],
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
