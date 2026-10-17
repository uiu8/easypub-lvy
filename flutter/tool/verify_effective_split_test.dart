import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('split node identity survives project and subsequent edits', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final run = await Directory(
      '../artifacts/r4-effective-split/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${run.absolute.path}/原稿.txt');
    const raw = '001 起\n甲文\n后半正文\n002 续\n乙文\n';
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
      final first = base['nodes'][0]['entry_id'];
      final body = (await state.manuscript.effectiveTree(
        id,
        0,
        previewNodeId: first,
      ))['body_preview'];
      expect(body['total'], 2);
      expect(body['rows'][1]['text'], '后半正文');
      expect(body['rows'][1]['line_offset'], 2);
      expect(
        await state.manuscript.editEffectiveDraft(id, {
          'op': 'append',
          'action': {
            'kind': 'split',
            'entry_id': first,
            'line_offset': 2,
            'title': '第三章 新章',
          },
        }),
        true,
      );
      final splitTree = await state.manuscript.effectiveTree(id, 0);
      final second = splitTree['nodes'][1]['entry_id'];
      expect(second, startsWith('inserted:'));
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
      final movedBody = (await reopened.manuscript.effectiveTree(
        id,
        0,
        previewNodeId: second,
      ))['body_preview'];
      expect(movedBody['total'], 1);
      expect(movedBody['rows'][0]['text'], '后半正文');
      expect(movedBody['rows'][0]['source_line'], 2);
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
      expect(await output.readAsString(), '新续章\n后半正文\n第一章 起\n甲文\n第二章 续\n乙文\n');
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
      await File('../docs/evidence/r4-effective-split.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'receipt': receipt,
          'checks': [
            'body preview uses composed nodes before split and after move reopen',
            'undo save reopen redo',
            'split then move rename classify keeps new identity and tree after reopen',
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
