import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_helpers.dart';

void main() {
  test('duplicate-title cleanup uses one preview and safe output transaction', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('build/windows/x64/runner/Release/easypub_bridge.dll')
            .absolute
            .path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r4-duplicate-cleanup/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    const raw = '第一章 甲\n正文\n\n第二章 乙\n\n第二章 乙\n中间正文\n第二章 乙\n尾声';
    final file = File('${dir.absolute.path}/重复标题.txt');
    await file.writeAsString(raw);
    final state = PrototypeState(), restored = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final id = state.currentId;
      final source = state.current.source!;
      final request = {
        'kind': 'cleanup',
        'pipeline': [
          {'kind': 'remove_duplicate_titles'},
        ],
      };
      final publication = {'kind': 'publication', 'cleanup': request};
      final plan = jsonDecode(
        await api.previewRepairPlanText(
          sourceId: source.sourceId,
          revision: source.revision,
          selectedJson: jsonEncode(publication),
        ),
      ) as Map<String, dynamic>;
      expect(plan['change_count'], 1);
      expect(plan['actions'][0]['source_line'], 6);
      expect(plan['actions'][0]['after'], isNull);
      expect(plan['actions'][0]['reason'], 'duplicate_title');
      expect(plan['actions'][0]['step_index'], 0);
      await state.cleanup.saveSettings(id, request);
      expect(
        (state.cleanup.drafts[id]!['pipeline'] as List).single['kind'],
        'remove_duplicate_titles',
      );

      final project = '${dir.absolute.path}/重复标题.easypub.json';
      await state.saveProjectOutcome(project);
      await restored.openProjectOutcome(project);
      expect(
        (restored.cleanup.drafts[id]!['pipeline'] as List).single['kind'],
        'remove_duplicate_titles',
      );

      final output = '${dir.absolute.path}/修订.txt';
      final currentSource = restored.shelf.books
          .firstWhere((book) => book.id == id)
          .source!;
      final receipt = jsonDecode(
        await api.commitRepairOutputText(
          sourceId: currentSource.sourceId,
          revision: currentSource.revision,
          sourcePath: file.path,
          outputPath: output,
          selectedJson: jsonEncode(publication),
          planId: plan['plan_id'] as String,
          confirmed: true,
        ),
      ) as Map<String, dynamic>;
      expect(receipt['committed'], true);
      expect(
        await File(output).readAsString(),
        '第一章 甲\n正文\n\n第二章 乙\n\n中间正文\n第二章 乙\n尾声',
      );
      expect(await file.readAsString(), raw);
      expect(
        await File('${receipt['transaction_dir']}/source-backup.bin')
            .readAsString(),
        raw,
      );
      final evidence = jsonDecode(
        await File('${receipt['transaction_dir']}/edit-evidence.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      expect(
        evidence['cleanup']['stage']['request']['pipeline'][0]['kind'],
        'remove_duplicate_titles',
      );
      expect(evidence['cleanup']['stage']['changes'][0]['reason'], 'duplicate_title');
      await File('../docs/evidence/r4-duplicate-cleanup.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': '',
          'checks': [
            'duplicate-title is an ordered cleanup rule',
            'only proven blank-separated adjacent duplicate headings are removed',
            'same title with intervening body remains',
            'project history restores the unified cleanup setting',
            'output transaction keeps source and backup unchanged',
            'audit records duplicate_title stage and source line',
          ],
          'limitations': [
            'synthetic TXT and actual DLL; complete R4/R5 and reader output remain pending',
          ],
        }),
      );
    } finally {
      state.dispose();
      restored.dispose();
    }
  });
}
