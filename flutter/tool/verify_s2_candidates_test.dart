import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'S2 exact chapter candidates and explicit exclusions preserve 690 bodies',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File(
            Platform.environment['EASYPUB_TEST_DLL'] ??
                '../target/release/easypub_bridge.dll',
          ).absolute.path,
        ),
      );
      final run = Directory(
        '../artifacts/r4-matrix-s2/${DateTime.now().microsecondsSinceEpoch}',
      ).absolute..createSync(recursive: true);
      final file = File('../samples/章节独立场景/S2/缺陷样书.txt')
          .copySync('${run.path}/S2.txt');
      final original = file.readAsBytesSync();
      final state = PrototypeState(), restored = PrototypeState();
      addTearDown(state.dispose);
      addTearDown(restored.dispose);
      await state.importBookOutcome(file.path);
      final source = state.current.source!, id = state.currentId;
      Future<Map> candidates(int offset) async => jsonDecode(
        await api.duplicateBlocksText(
          sourceId: source.sourceId,
          revision: source.revision,
          offset: offset,
        ),
      ) as Map;
      final report = await candidates(0);
      expect(report['groups'], 11);
      expect(report['total'], 22);
      expect((await candidates(22))['rows'], isEmpty);
      await expectLater(candidates(23), throwsA(anything));
      final truth = jsonDecode(
        File('../samples/章节独立场景/S2/真值清单.json').readAsStringSync(),
      ) as Map;
      final duplicateStarts = {
        for (final instance in truth['instances'] as List)
          if (instance['duplicate'] == true) instance['start_line'],
      };
      final draft = jsonDecode(
        await api.editManualDraft(
          sourceId: source.sourceId,
          revision: source.revision,
          draftJson: '',
          commandJson: jsonEncode({
            'op': 'exclude_duplicate_blocks',
            'entry_ids': [
              for (final row in report['rows'] as List)
                if (duplicateStarts.contains(row['start_line']))
                  row['entry_id'],
            ],
          }),
        ),
      ) as Map<String, dynamic>;
      expect(draft['cursor'], 1);
      expect((draft['history'][draft['cursor']] as List).length, 11);
      state.manuscript.manualEditDrafts[id] = draft;
      final project = '${run.path}/S2.easypub.json';
      await state.saveProjectOutcome(project);
      await restored.openProjectOutcome(project);
      expect(restored.manuscript.manualEditDrafts[id], draft);
      final request = jsonEncode({
        'kind': 'manual_batch',
        'actions': draft['history'][draft['cursor']],
      });
      final plan = jsonDecode(
        await api.previewRepairPlanText(
          sourceId: source.sourceId,
          revision: source.revision,
          selectedJson: request,
        ),
      ) as Map;
      final output = File('${run.path}/S2-副本.txt');
      final receipt = jsonDecode(
        await api.commitRepairOutputText(
          sourceId: source.sourceId,
          revision: source.revision,
          sourcePath: file.path,
          outputPath: output.path,
          selectedJson: request,
          planId: plan['plan_id'] as String,
          confirmed: true,
        ),
      ) as Map;
      expect(receipt['committed'], true);
      expect(
        output.readAsBytesSync(),
        File('../samples/章节独立场景/S2/完整原稿.txt').readAsBytesSync(),
      );
      expect(file.readAsBytesSync(), original);
      expect(
        File('${receipt['transaction_dir']}/source-backup.bin')
            .readAsBytesSync(),
        original,
      );
      File('../docs/evidence/r4-matrix-s2-candidates.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'passed_partial': true,
          'scenario': 'S2',
          'mode': 'M3',
          'report': report,
          'receipt': receipt,
          'output': output.path,
          'checks': [
            '11 exact nonempty-body groups',
            'all 22 occurrences offered, no default deletion',
            'oracle explicitly selects 11 duplicate ranges',
            'project restores exact choices',
            'output byte-equal to full 690-chapter truth',
            'source and backup intact',
            'invalid pagination rejected',
          ],
          'not_verified': [
            'candidate selection UI',
            'full matrix cell',
            'EPUB/Kindling and reader',
          ],
        }),
      );
    },
  );
}
