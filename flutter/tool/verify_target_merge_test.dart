import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cross-parent merge follows insert move and rename with saved history', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final dir = Directory(
      '../artifacts/r4-target-merge/${DateTime.now().microsecondsSinceEpoch}',
    ).absolute..createSync(recursive: true);
    const raw = '总集\n前置正文\n旧部\n旧部正文\n第一章 甲\n甲正文\n节甲\n节正文\n第二章 乙\n乙正文\n尾卷\n尾正文';
    final file = File('${dir.path}/原稿.txt')..writeAsStringSync(raw);
    final state = PrototypeState(), reopened = PrototypeState();
    addTearDown(state.dispose);
    addTearDown(reopened.dispose);
    await state.importBookOutcome(file.path);
    final id = state.currentId, source = state.current.source!;
    state.manuscript.structures[id] = {
      'source_id': source.sourceId,
      'revision': source.revision,
      'overrides': [
        for (final (line, role, depth) in [
          (1, 'volume', 0),
          (3, 'volume', 1),
          (5, 'chapter', 2),
          (7, 'section', 3),
          (9, 'chapter', 2),
          (11, 'volume', 0),
        ])
          {
            'source_line': line,
            'role': role,
            'depth': depth,
            'include_toc': line != 7,
          },
      ],
    };
    final base = (await state.manuscript.effectiveTree(id, 0))['nodes'] as List;
    final parent = base[1]['entry_id'],
        chapter = base[2]['entry_id'],
        section = base[3]['entry_id'];
    await state.manuscript.editEffectiveDraft(id, {
      'op': 'append',
      'action': {'kind': 'insert_volume', 'entry_id': chapter, 'title': '新部'},
    });
    final inserted = (await state.manuscript.effectiveTree(id, 0))['nodes'] as List;
    final volume = inserted[2]['entry_id'];
    expect(inserted[2]['depth'], 1);
    expect(inserted[3]['parent_id'], volume);
    expect(inserted[4]['entry_id'], section);
    expect(inserted[4]['parent_id'], chapter);
    expect(inserted[4]['include_toc'], false);
    await state.manuscript.editEffectiveDraft(id, {
      'op': 'append',
      'action': {
        'kind': 'move_subtree',
        'entry_id': volume,
        'before_id': parent,
      },
    });
    await state.manuscript.editEffectiveDraft(id, {
      'op': 'append',
      'action': {'kind': 'rename', 'entry_id': volume, 'title': '新部定稿'},
    });
    await state.manuscript.editEffectiveDraft(id, {
      'op': 'append',
      'action': {
        'kind': 'merge_into',
        'entry_id': chapter,
        'target_id': parent,
      },
    });
    final mergedNodes = (await state.manuscript.effectiveTree(id, 0))['nodes'] as List;
    final child = mergedNodes.singleWhere((n) => n['entry_id'] == section);
    expect(child['depth'], 2);
    expect(child['parent_id'], parent);
    expect(child['include_toc'], false);
    expect(mergedNodes.any((n) => n['entry_id'] == chapter), false);
    final finalTree = (await state.manuscript.effectiveTree(id, 0))['nodes'];
    final complete = jsonEncode(state.manuscript.effectiveHistories[id]);
    await state.manuscript.editEffectiveDraft(id, {'op': 'undo'});
    final project = '${dir.path}/项目.easypub.json';
    await state.saveProjectOutcome(project);
    expect(File(project).existsSync(), true, reason: state.projectStatus);
    await reopened.openProjectOutcome(project);
    await reopened.manuscript.editEffectiveDraft(id, {'op': 'redo'});
    expect(jsonEncode(reopened.manuscript.effectiveHistories[id]), complete);
    expect((await reopened.manuscript.effectiveTree(id, 0))['nodes'], finalTree);
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
    ) as Map;
    final output = File('${dir.path}/副本.txt');
    final receipt = jsonDecode(
      await api.commitRepairOutputText(
        sourceId: source.sourceId,
        revision: source.revision,
        sourcePath: file.path,
        outputPath: output.path,
        selectedJson: jsonEncode(request),
        planId: plan['plan_id'] as String,
        confirmed: true,
      ),
    ) as Map;
    expect(receipt['committed'], true);
    expect(
      output.readAsStringSync(),
      '总集\n前置正文\n新部定稿\n第二章 乙\n乙正文\n旧部\n旧部正文\n甲正文\n节甲\n节正文\n尾卷\n尾正文',
    );
    expect(file.readAsStringSync(), raw);
    expect(
      File('${receipt['transaction_dir']}/source-backup.bin').readAsBytesSync(),
      file.readAsBytesSync(),
    );
    final audit = jsonDecode(
      File('${receipt['transaction_dir']}/edit-evidence.json')
          .readAsStringSync(),
    ) as Map;
    final resources = await reopened.production.publicationResources(id);
    expect(audit['text_utf8_sha256'], resources['manifest']['text_sha256']);
    File('../docs/evidence/r4-target-merge.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'passed': true,
        'receipt': receipt,
        'checks': [
          'depth 2 insertion with depth 3 section',
          'original IDs and hidden section preserved',
          'subtree move and rename then cross-parent chapter into volume merge',
          'undo/save/open/redo',
          'exact TXT and resource hash',
          'source and backup intact',
        ],
        'not_verified': ['full 36-cell matrix', 'real desktop interaction'],
      }),
    );
  });
}
