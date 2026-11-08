import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'post cleanup node edits agree across tree positions resources and output',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File('../target/release/easypub_bridge.dll').absolute.path,
        ),
      );
      final run = await Directory(
        '../artifacts/r4-post-cleanup/${DateTime.now().microsecondsSinceEpoch}',
      ).create(recursive: true);
      final file = File('${run.absolute.path}/原稿.txt');
      const raw = '001 起\n甲文\n002 续\n乙文\n003 终\n丙文\n';
      await file.writeAsString(raw);
      final state = PrototypeState();
      try {
        await state.importBookOutcome(file.path);
        final source = state.current.source!;
        final cleanup = {
          'kind': 'cleanup',
          'pipeline': [
            {
              'kind': 'chapter_numbers',
              'style': 'chinese',
              'bare_titles': true,
            },
          ],
        };
        Future<Map> tree(Map? edits) async => jsonDecode(
          await api.effectiveStructureText(
            sourceId: source.sourceId,
            revision: source.revision,
            settingsJson: '',
            offset: 0,
            selectedJson: jsonEncode({
              'kind': 'publication',
              'cleanup': cleanup,
              'post_edits': edits,
            }),
          ),
        ) as Map;
        final base = await tree(null);
        final first = base['nodes'][0]['entry_id'],
            second = base['nodes'][1]['entry_id'];
        final edits = {
          'base_id': base['editing_base_id'],
          'actions': [
            {'kind': 'move', 'entry_id': second, 'before_id': first},
            {'kind': 'rename', 'entry_id': second, 'title': '无编号续章'},
            {'kind': 'merge_previous', 'entry_id': first},
          ],
        };
        final after = await tree(edits);
        expect(after['nodes'], hasLength(2));
        expect(after['nodes'][0]['entry_id'], second);
        expect(after['nodes'][0]['title'], '无编号续章');
        final positions = jsonDecode(
          await api.illustrationPositionsText(
            sourceId: source.sourceId,
            revision: source.revision,
            requestJson: jsonEncode({
              'source_lines': [4, 1],
              'cleanup': cleanup,
              'post_edits': edits,
            }),
          ),
        );
        expect(positions['positions'][0]['output_line'], 2);
        expect(positions['positions'][1]['status'], 'needs_relocation');
        final resources = jsonDecode(
          await api.publicationResourcesText(
            requestJson: jsonEncode({
              'source_id': source.sourceId,
              'revision': source.revision,
              'settings': state.production.settings(state.currentId),
              'cleanup': cleanup,
              'post_edits': edits,
            }),
          ),
        );
        final selected = {
          'kind': 'publication',
          'cleanup': cleanup,
          'post_edits': edits,
        };
        final plan = jsonDecode(
          await api.previewRepairPlanText(
            sourceId: source.sourceId,
            revision: source.revision,
            selectedJson: jsonEncode(selected),
          ),
        );
        expect(plan['editing_base_id'], base['editing_base_id']);
        await expectLater(
          tree({...edits, 'base_id': '0' * 64}),
          throwsA(anything),
        );
        await expectLater(
          tree({
            ...edits,
            'actions': [
              ...(edits['actions'] as List),
              {'kind': 'rename', 'entry_id': first, 'title': '不能错改邻章'},
            ],
          }),
          throwsA(anything),
        );
        final output = File('${run.absolute.path}/副本.txt');
        final receipt = jsonDecode(
          await api.commitRepairOutputText(
            sourceId: source.sourceId,
            revision: source.revision,
            sourcePath: file.path,
            outputPath: output.path,
            selectedJson: jsonEncode(selected),
            planId: plan['plan_id'],
            confirmed: true,
          ),
        );
        expect(receipt['committed'], true);
        expect(await output.readAsString(), '无编号续章\n乙文\n甲文\n第三章 终\n丙文\n');
        final audit = jsonDecode(
          await File('${receipt['transaction_dir']}/edit-evidence.json')
              .readAsString(),
        );
        expect(audit['post_edits'], hasLength(3));
        expect(audit['text_utf8_sha256'], resources['manifest']['text_sha256']);
        expect(await file.readAsString(), raw);
        expect(
          await File('${receipt['transaction_dir']}/source-backup.bin')
              .readAsBytes(),
          await file.readAsBytes(),
        );
        await File('../docs/evidence/r4-post-cleanup-edit.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'passed': true,
            'verified_at': DateTime.now().toIso8601String(),
            'receipt': receipt,
            'checks': [
              'ordered move rename merge of promoted nodes',
              'stable identities',
              'illustration relocation',
              'resource and output hashes agree',
              'stale base and deleted node rejected',
              'source and backup unchanged',
            ],
            'not_verified': ['editing UI', 'project history persistence'],
          }),
        );
      } finally {
        state.dispose();
      }
    },
  );
}
