import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('inserted volume and split chapter moves survive project and commit', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final run = await Directory(
      '../artifacts/r4-inserted-moves/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final reports = <Map>[];
    for (final volume in [true, false]) {
      final state = PrototypeState(), reopened = PrototypeState();
      final sourceFile = File('${run.absolute.path}/原稿-$volume.txt');
      const original = '第一章 甲\n甲上\n甲下\n第二章 乙\n乙文\n';
      await sourceFile.writeAsString(original);
      try {
        await state.importBookOutcome(sourceFile.path);
        final source = state.current.source!, id = state.currentId;
        Map<String, dynamic>? draft;
        Future<void> command(Map<String, dynamic> cmd) async {
          draft = (jsonDecode(
            await api.editManualDraft(
              sourceId: source.sourceId,
              revision: source.revision,
              draftJson: draft == null ? '' : jsonEncode(draft),
              commandJson: jsonEncode(cmd),
            ),
          ) as Map).cast<String, dynamic>();
        }

        if (volume) {
          for (final item in [(1, '启程'), (4, '归来')]) {
            await command({
              'op': 'put',
              'action': {
                'kind': 'set_volume',
                'source_line': item.$1,
                'volume_title': item.$2,
              },
            });
          }
        } else {
          await command({
            'op': 'put',
            'action': {
              'kind': 'split_chapter',
              'source_line': 3,
              'title': '第二章 新章',
            },
          });
        }
        await command({
          'op': 'put',
          'action': {
            'kind': volume ? 'move_volume' : 'move_chapter',
            'source_line': volume ? 4 : 3,
            'before_line': 1,
          },
        });
        final complete = jsonEncode(draft);
        await command({'op': 'undo'});
        state.manuscript.manualEditDrafts[id] = draft!;
        final project = '${run.absolute.path}/项目-$volume.easypub.json';
        await state.saveProjectOutcome(project);
        expect(File(project).existsSync(), true, reason: state.projectStatus);
        await reopened.openProjectOutcome(project);
        draft = reopened.manuscript.manualEditDrafts[id];
        await command({'op': 'redo'});
        expect(jsonEncode(draft), complete);
        final selection = jsonEncode({
          'kind': 'manual_batch',
          'actions': draft!['history'][draft!['cursor']],
        });
        final plan = jsonDecode(
          await api.previewRepairPlanText(
            sourceId: source.sourceId,
            revision: source.revision,
            selectedJson: selection,
          ),
        );
        final output = File('${run.absolute.path}/副本-$volume.txt');
        final receipt = jsonDecode(
          await api.commitRepairOutputText(
            sourceId: source.sourceId,
            revision: source.revision,
            sourcePath: sourceFile.path,
            outputPath: output.path,
            selectedJson: selection,
            planId: plan['plan_id'],
            confirmed: true,
          ),
        );
        expect(receipt['committed'], true);
        expect(
          await output.readAsString(),
          volume
              ? '归来\n第二章 乙\n乙文\n启程\n第一章 甲\n甲上\n甲下\n'
              : '第二章 新章\n甲下\n第一章 甲\n甲上\n第二章 乙\n乙文\n',
        );
        expect(await sourceFile.readAsString(), original);
        expect(
          await File('${receipt['transaction_dir']}/source-backup.bin')
              .readAsBytes(),
          await sourceFile.readAsBytes(),
        );
        reports.add({
          'inserted_kind': volume ? 'volume' : 'chapter',
          'receipt': receipt,
        });
      } finally {
        state.dispose();
        reopened.dispose();
      }
    }
    await File('../docs/evidence/r4-inserted-moves.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'passed': true,
        'verified_at': DateTime.now().toIso8601String(),
        'cases': reports,
        'checks': [
          'insert then move in same draft',
          'undo save reopen redo',
          'exact output',
          'source and backup unchanged',
        ],
      }),
    );
  });
}
