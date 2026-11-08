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
    'multiline cleanup restores settings and preserves complete source spans',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File('build/windows/x64/runner/Release/easypub_bridge.dll')
              .absolute
              .path,
        ),
      );
      final dir = await Directory(
        '../artifacts/r5-multiline/${DateTime.now().microsecondsSinceEpoch}',
      ).create(recursive: true);
      final file = File('${dir.absolute.path}/原稿.txt');
      const text = '第一章 甲\r\n甲上\r\n甲下\n未改行\r第二章 乙\n结束';
      await file.writeAsBytes(utf16(text));
      final state = PrototypeState(), restored = PrototypeState();
      try {
        await state.importBookOutcome(file.path);
        final source = state.current.source!;
        final cleanup = <String, dynamic>{
          'kind': 'cleanup',
          'pipeline': [
            {
              'kind': 'multiline_regex_replace',
              'pattern': r'(?P<name>甲)上\r\n甲下',
              'replace': r'${name}合并\n新增\n三行  ',
            },
            {'kind': 'regex_replace', 'pattern': '^新增\$', 'replace': '新的一行'},
            {'kind': 'trim_trailing_spaces'},
          ],
        };
        state.cleanup.drafts[state.currentId] = cleanup;
        final project = '${dir.absolute.path}/跨行.easypub.json';
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
        final raw = await preview(cleanup);
        expect(raw['change_count'], 1);
        expect(raw['actions'][0]['source_line'], 2);
        expect(raw['actions'][0]['source_end_line'], 3);
        expect(raw['actions'][0]['before'], '甲上\r\n甲下\n');
        expect(raw['stage_count'], 3);
        expect(
          (await preview({
            ...cleanup,
            'skip_lines': [2, 3],
          }))['change_count'],
          0,
        );
        await expectLater(
          preview({
            'kind': 'cleanup',
            'pipeline': [
              {
                'kind': 'multiline_regex_replace',
                'pattern': '甲',
                'replace': r'$unknown',
              },
            ],
          }),
          throwsA(anything),
        );
        final combined = <String, dynamic>{
          'kind': 'publication',
          'cleanup': restored.cleanup.drafts[restored.currentId],
          'manual': {
            'kind': 'manual_batch',
            'actions': [
              {'kind': 'rename_title', 'source_line': 5, 'title': '第二章 修订'},
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
        changed['cleanup']['pipeline'][0]['replace'] = '另一结果';
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
          utf16('第一章 甲\r\n甲合并\n新的一行\n三行\n未改行\r第二章 修订\n结束'),
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
        final stage = evidence['cleanup']['stage'];
        expect(stage['source_to_output_ranges'][1]['source_line'], 2);
        expect(stage['source_to_output_ranges'][1]['source_end_line'], 3);
        expect(stage['source_to_output_ranges'][1]['mapping'], 'region');
        expect(stage['source_to_output_ranges'][1]['output_line'], 2);
        expect(stage['source_to_output_ranges'][1]['output_end_line'], 4);
        expect(stage['source_to_output_lines'], [
          [1, 1],
          [4, 5],
          [5, 6],
          [6, 7],
        ]);
        expect(evidence['effective_structure']['nodes'], hasLength(2));
        expect(evidence['effective_structure']['nodes'][1]['source_line'], 6);
        expect(stage['changes'][0]['before'], '甲上\r\n甲下\n');
        expect(stage['stages'], hasLength(3));
        await expectLater(
          commit(combined, plan['plan_id'], true),
          throwsA(anything),
        );
        await File('../docs/evidence/r5-multiline.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'passed': true,
            'verified_at': DateTime.now().toIso8601String(),
            'receipt': receipt,
            'checks': [
              'exact UTF16LE bytes, BOM and mixed endings',
              'original and backup unchanged',
              'multiple source lines to multiple output lines have region provenance',
              'following per-line regex and trim see each inserted line',
              'whole source span skip',
              'project settings restore',
              'manual title edit and final structure coordinates',
              'unknown captures, stale plans, missing confirmation and output overwrite rejected',
            ],
            'limitations': [
              'continuous body block limited to 256 KiB',
              'original boundary ending retained',
              'dictionary conversion and full R4/R5 acceptance pending',
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
