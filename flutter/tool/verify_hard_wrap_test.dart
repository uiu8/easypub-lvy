import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> utf16(String s) => [
  255,
  254,
  for (final c in s.codeUnits) ...[c & 255, c >> 8],
];

void main() {
  test(
    'hard wraps preserve encoded content, source spans and project recovery',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File('build/windows/x64/runner/Release/easypub_bridge.dll')
              .absolute
              .path,
        ),
      );
      final dir = await Directory(
        '../artifacts/r5-hard-wrap/${DateTime.now().microsecondsSinceEpoch}',
      ).create(recursive: true);
      final file = File('${dir.absolute.path}/原稿.txt');
      const text = '第一章 甲\r\n这是长长的断\r行继续。\n第二章 乙\n另一处长长断\r\n行完成。\r';
      await file.writeAsBytes(utf16(text));
      final state = PrototypeState(), restored = PrototypeState();
      try {
        await state.importBookOutcome(file.path);
        final source = state.current.source!;
        final cleanup = <String, dynamic>{
          'kind': 'cleanup',
          'pipeline': [
            {'kind': 'join_hard_wraps', 'mode': 'chinese', 'min_chars': 4},
            {'kind': 'literal_replace', 'find': '断行', 'replace': '整句'},
          ],
        };
        state.cleanup.drafts[state.currentId] = cleanup;
        final project = '${dir.absolute.path}/合并.easypub.json';
        await state.saveProjectOutcome(project);
        expect(await File(project).exists(), true, reason: state.projectStatus);
        await restored.openProjectOutcome(project);
        expect(
          restored.cleanup.drafts[restored.currentId]!['pipeline'],
          cleanup['pipeline'],
        );
        Future<Map<String, dynamic>> preview(Map<String, dynamic> r) async =>
            jsonDecode(
              await api.previewRepairPlanText(
                sourceId: source.sourceId,
                revision: source.revision,
                selectedJson: jsonEncode(r),
              ),
            ) as Map<String, dynamic>;
        final rawPlan = await preview(cleanup);
        expect(rawPlan['change_count'], 2);
        expect(rawPlan['actions'][0]['source_line'], 2);
        expect(rawPlan['actions'][0]['source_end_line'], 3);
        expect(rawPlan['actions'][0]['before'], '这是长长的断\r行继续。\n');
        final skipped = await preview({
          ...cleanup,
          'skip_lines': [2, 3],
        });
        expect(skipped['change_count'], 1);
        final combined = <String, dynamic>{
          'kind': 'publication',
          'cleanup': restored.cleanup.drafts[restored.currentId],
          'manual': {
            'kind': 'manual_batch',
            'actions': [
              {'kind': 'move_chapter', 'source_line': 4, 'before_line': 1},
            ],
          },
        };
        final plan = await preview(combined);
        final output = File('${dir.absolute.path}/输出.txt');
        Future<String> commit(
          Map<String, dynamic> r,
          String id,
          bool confirmed,
        ) => api.commitRepairOutputText(
          sourceId: source.sourceId,
          revision: source.revision,
          sourcePath: file.path,
          outputPath: output.path,
          selectedJson: jsonEncode(r),
          planId: id,
          confirmed: confirmed,
        );
        await expectLater(
          commit(combined, plan['plan_id'], false),
          throwsA(anything),
        );
        final changed =
            jsonDecode(jsonEncode(combined)) as Map<String, dynamic>;
        changed['cleanup']['pipeline'][0]['min_chars'] = 40;
        await expectLater(
          commit(changed, plan['plan_id'], true),
          throwsA(anything),
        );
        expect(await output.exists(), false);
        final receipt = jsonDecode(
          await commit(combined, plan['plan_id'], true),
        );
        expect(
          await output.readAsBytes(),
          utf16('第二章 乙\n另一处长长整句完成。\r第一章 甲\r\n这是长长的整句继续。\n'),
        );
        expect(await file.readAsBytes(), utf16(text));
        expect(
          await File('${receipt['transaction_dir']}/source-backup.bin')
              .readAsBytes(),
          utf16(text),
        );
        final evidence = jsonDecode(
          await File('${receipt['transaction_dir']}/edit-evidence.json')
              .readAsString(),
        );
        expect(evidence['cleanup']['stage']['source_to_output_lines'], [
          [1, 1],
          [2, 2],
          [3, 2],
          [4, 3],
          [5, 4],
          [6, 4],
        ]);
        expect(evidence['cleanup']['source_line_origins']['2'], 5);
        expect(evidence['effective_structure']['nodes'], hasLength(2));
        expect(evidence['effective_structure']['nodes'][1]['source_line'], 3);
        expect(
          evidence['cleanup']['stage']['stages'][0]['before'],
          '另一处长长断\r\n行完成。\r',
        );
        await expectLater(
          commit(combined, plan['plan_id'], true),
          throwsA(anything),
        );
        await File('../docs/evidence/r5-hard-wrap.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'passed': true,
            'verified_at': DateTime.now().toIso8601String(),
            'receipt': receipt,
            'checks': [
              'UTF16LE BOM and unchanged endings match exact expected bytes',
              'source and backup unchanged',
              'source ranges contain complete pre-join content',
              'whole span skip prevents join',
              'settings restored from project',
              'moved chapter source mapping and stable structure preserved',
              'confirmation and old plan rejected',
              'existing output not overwritten',
            ],
            'limitations': [
              'heuristic paragraph semantics still require review',
              'dictionary conversion and complete R4/R5 acceptance pending',
            ],
          }),
        );
      } finally {
        state.dispose();
        restored.dispose();
      }
    },
  );
}
