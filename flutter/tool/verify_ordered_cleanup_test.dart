import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ordered cleanup survives project recovery and moved chapter output', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('build/windows/x64/runner/Release/easypub_bridge.dll')
            .absolute
            .path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r5-ordered-cleanup/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${dir.absolute.path}/原稿.txt');
    const body = '第一章 甲\r\nＡ１２﹗  \n本章完\r\n第二章 乙\r乙文  \n';
    await file.writeAsString(body);
    final state = PrototypeState(), restored = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final source = state.current.source!;
      final pipeline = <Map<String, dynamic>>[
        {'kind': 'normalize_width'},
        {
          'kind': 'regex_replace',
          'pattern': r'(?<l>[A-Z])(?<n>\d+)',
          'replace': r'${n}-${l}',
        },
        {'kind': 'normalize_punctuation'},
        {'kind': 'trim_trailing_spaces'},
        {'kind': 'remove_ad_lines'},
      ];
      final cleanup = <String, dynamic>{
        'kind': 'cleanup',
        'pipeline': pipeline,
        'start_line': 2,
        'end_line': 5,
        'skip_lines': [5],
        'remove_lines': [3],
      };
      state.cleanup.drafts[state.currentId] = cleanup;
      final project = '${dir.absolute.path}/有序清理.easypub.json';
      await state.saveProjectOutcome(project);
      expect(await File(project).exists(), true, reason: state.projectStatus);
      await restored.openProjectOutcome(project);
      expect(
        restored.cleanup.drafts[restored.currentId]!['pipeline'],
        pipeline,
        reason: restored.projectStatus,
      );
      final request = <String, dynamic>{
        'kind': 'publication',
        'manual': {
          'kind': 'manual_batch',
          'actions': [
            {'kind': 'move_chapter', 'source_line': 4, 'before_line': 1},
          ],
        },
        'cleanup': restored.cleanup.drafts[restored.currentId],
      };
      Future<Map<String, dynamic>> preview(
        Map<String, dynamic> request,
      ) async => jsonDecode(
        await api.previewRepairPlanText(
          sourceId: source.sourceId,
          revision: source.revision,
          selectedJson: jsonEncode(request),
        ),
      ) as Map<String, dynamic>;
      final plan = await preview(request);
      final changed = jsonDecode(jsonEncode(request)) as Map<String, dynamic>;
      (changed['cleanup']['pipeline'] as List).removeAt(0);
      final different = await preview(changed);
      expect(different['plan_id'], isNot(plan['plan_id']));
      final output = File('${dir.absolute.path}/组合输出.txt');
      Future<String> commit(
        Map<String, dynamic> selection,
        String id,
        bool confirmed,
      ) => api.commitRepairOutputText(
        sourceId: source.sourceId,
        revision: source.revision,
        sourcePath: file.path,
        outputPath: output.path,
        selectedJson: jsonEncode(selection),
        planId: id,
        confirmed: confirmed,
      );
      await expectLater(
        commit(request, plan['plan_id'], false),
        throwsA(anything),
      );
      await expectLater(
        commit(changed, plan['plan_id'], true),
        throwsA(anything),
      );
      expect(await output.exists(), false);
      final receipt = jsonDecode(await commit(request, plan['plan_id'], true));
      expect(await output.readAsString(), '第二章 乙\r乙文  \n第一章 甲\r\n12-A！\n');
      expect(await file.readAsString(), body);
      expect(
        await File('${receipt['transaction_dir']}/source-backup.bin')
            .readAsBytes(),
        await file.readAsBytes(),
      );
      final evidence = jsonDecode(
        await File('${receipt['transaction_dir']}/edit-evidence.json')
            .readAsString(),
      );
      final stage = evidence['cleanup']['stage'];
      expect(stage['stages'], hasLength(5));
      expect(stage['stages'][0]['before'], 'Ａ１２﹗  ');
      expect(stage['stages'][1]['before'], 'A12﹗  ');
      expect(stage['stages'][1]['after'], '12-A﹗  ');
      expect(evidence['cleanup']['source_line_origins']['4'], 2);
      expect(evidence['effective_structure']['nodes'], hasLength(2));
      await expectLater(
        commit(request, plan['plan_id'], true),
        throwsA(anything),
      );
      final bad = jsonDecode(await File(project).readAsString());
      bad['books'][0]['cleanup']['pipeline'][1]['replace'] = r'$absent';
      final invalid = File('${dir.absolute.path}/无效规则.easypub.json');
      await invalid.writeAsString(jsonEncode(bad));
      await restored.openProjectOutcome(invalid.path);
      expect(restored.projectPath, project);
      expect(restored.cleanup.drafts[restored.currentId]!['pipeline'], pipeline);
      await File('../docs/evidence/r5-ordered-cleanup.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'receipt': receipt,
          'checks': [
            'ordered rules restored from project',
            'custom captures and exact punctuation output',
            'source range and skip follow moved chapter',
            'complete intermediate stage evidence with source map',
            'source and backup byte equality',
            'old plan and missing confirmation rejected',
            'invalid capture in project keeps current state',
            'existing output protected',
          ],
          'limitations': [
            'cross-line transformations and dictionary conversion pending',
            'new UI visual review pending',
          ],
        }),
      );
    } finally {
      state.dispose();
      restored.dispose();
    }
  });
}
