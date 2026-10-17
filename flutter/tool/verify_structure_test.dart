import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('structure classification and hierarchy survive project reopen without changing source', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('build/windows/x64/runner/Release/easypub_bridge.dll')
            .absolute
            .path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r4-structure/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${dir.absolute.path}/原稿.txt');
    const text = '卷前文字\n第一卷 起  \n卷首说明\n第一章 甲\n甲文\n第二章 误识别\n仍是甲文\n第三章 丙\n丙文';
    await file.writeAsString(text);
    final state = PrototypeState(), reopened = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final source = state.current.source!;
      Map<String, dynamic>? settings;
      Future<Map<String, dynamic>> inspect([
        Map<String, dynamic>? change,
      ]) async {
        return jsonDecode(
          await api.chapterStructureText(
            sourceId: source.sourceId,
            revision: source.revision,
            settingsJson: settings == null ? '' : jsonEncode(settings),
            changeJson: change == null ? '' : jsonEncode(change),
            offset: 0,
          ),
        ) as Map<String, dynamic>;
      }

      final base = await inspect();
      expect(base['total'], 4);
      var result = await inspect({
        'source_line': 6,
        'role': 'body',
        'depth': 0,
        'include_toc': false,
      });
      settings = (result['settings'] as Map).cast<String, dynamic>();
      result = await inspect({
        'source_line': 8,
        'role': 'section',
        'depth': 2,
        'include_toc': false,
      });
      settings = (result['settings'] as Map).cast<String, dynamic>();
      expect(result['total'], 3);
      final nodes = result['nodes'] as List;
      expect(nodes[2]['parent_id'], nodes[1]['entry_id']);
      expect(nodes[2]['include_toc'], false);
      expect(
        utf8.decode(
          utf8
              .encode(text)
              .sublist(nodes[1]['body_start'] as int, nodes[1]['end'] as int),
        ),
        contains('第二章 误识别\n仍是甲文'),
      );
      expect(result['source_bytes_covered'], utf8.encode(text).length);
      state.manuscript.structures[state.currentId] = settings;
      final cleanup = <String, dynamic>{
        'kind': 'cleanup',
        'rules': ['trim_trailing_spaces'],
        'start_line': 2,
        'end_line': 8,
        'skip_lines': [5],
        'remove_lines': <int>[],
        'preview_offset': 0,
      };
      state.cleanup.drafts[state.currentId] = cleanup;
      final project = '${dir.absolute.path}/结构.easypub.json';
      await state.saveProjectOutcome(project);
      expect(await File(project).exists(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(project);
      expect(
        reopened.manuscript.structures[reopened.currentId],
        settings,
        reason: reopened.projectStatus,
      );
      expect(reopened.cleanup.drafts[reopened.currentId], cleanup);
      settings = reopened.manuscript.structures[reopened.currentId];
      expect((await inspect())['nodes'], nodes);
      final composed = jsonDecode(
        await api.effectiveStructureText(
          sourceId: source.sourceId,
          revision: source.revision,
          settingsJson: jsonEncode(settings),
          selectedJson: jsonEncode({
            'kind': 'manual_batch',
            'actions': [
              {'kind': 'rename_title', 'source_line': 4, 'title': '无编号的新章名'},
            ],
          }),
          offset: 0,
        ),
      ) as Map<String, dynamic>;
      expect(composed['total'], 3);
      expect(composed['text_changed'], true);
      final editedNodes = composed['nodes'] as List;
      expect(editedNodes[1]['entry_id'], nodes[1]['entry_id']);
      expect(editedNodes[1]['title'], '无编号的新章名');
      expect(editedNodes[2]['include_toc'], false);
      expect(editedNodes[2]['parent_id'], editedNodes[1]['entry_id']);
      expect(composed['removed_structure_lines'], isEmpty);
      final cleaned = jsonDecode(
        await api.effectiveStructureText(
          sourceId: source.sourceId,
          revision: source.revision,
          settingsJson: jsonEncode(settings),
          selectedJson: jsonEncode({
            'kind': 'publication',
            'manual': {
              'kind': 'manual_batch',
              'actions': [
                {'kind': 'rename_title', 'source_line': 4, 'title': '无编号的新章名'},
              ],
            },
            'cleanup': reopened.cleanup.drafts[reopened.currentId],
          }),
          offset: 0,
        ),
      ) as Map<String, dynamic>;
      expect(
        cleaned['source_bytes_covered'],
        (composed['source_bytes_covered'] as int) - 2,
      );
      final cleanedNodes = cleaned['nodes'] as List;
      expect(cleanedNodes.length, editedNodes.length);
      for (var i = 0; i < editedNodes.length; i++) {
        expect(cleanedNodes[i]['entry_id'], editedNodes[i]['entry_id']);
        expect(cleanedNodes[i]['parent_id'], editedNodes[i]['parent_id']);
        expect(cleanedNodes[i]['include_toc'], editedNodes[i]['include_toc']);
      }

      await expectLater(
        inspect({
          'source_line': 4,
          'role': 'chapter',
          'depth': 8,
          'include_toc': true,
        }),
        throwsA(anything),
      );
      final badCleanup = jsonDecode(await File(project).readAsString());
      badCleanup['books'][0]['cleanup']['skip_lines'] = [999];
      final brokenCleanup = File('${dir.absolute.path}/错误清理.easypub.json');
      await brokenCleanup.writeAsString(jsonEncode(badCleanup));
      await reopened.openProjectOutcome(brokenCleanup.path);
      expect(reopened.projectPath, project);
      expect(reopened.cleanup.drafts[reopened.currentId], cleanup);
      final bad = jsonDecode(await File(project).readAsString());
      bad['books'][0]['structure']['overrides'][0]['source_line'] = 999;
      final broken = File('${dir.absolute.path}/错误结构.easypub.json');
      await broken.writeAsString(jsonEncode(bad));
      await reopened.openProjectOutcome(broken.path);
      expect(reopened.projectPath, project);
      expect(await file.readAsString(), text);
      await File('../docs/evidence/r4-structure.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'nodes': nodes,
          'composed_nodes': editedNodes,
          'cleaned_nodes': cleanedNodes,
          'checks': [
            'demoted heading text remains in previous body',
            'TOC exclusion retains node and content',
            'explicit parent hierarchy',
            'UTF-8 full coverage',
            'project reopen restores structure',
            'invalid depth rejected',
            'corrupt structure does not replace active project',
            'source unchanged',
            'composed cleanup reduces byte coverage while retaining node IDs parents and TOC',
            'cleanup rules range and skips restored; invalid cleanup keeps active project',
            'native manual batch rename and publication composition retain identities and logical hierarchy',
          ],
          'limitations': [
            'catalog composition pending',
            'publication export not connected',
          ],
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
