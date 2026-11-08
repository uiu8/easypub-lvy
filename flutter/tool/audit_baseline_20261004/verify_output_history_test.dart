import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Rust task history reopens terminal and interrupted observations',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File(Platform.environment['EASYPUB_TEST_DLL'] ?? '../target/release/easypub_bridge.dll').absolute.path,
        ),
      );
      final dir = Directory(
        '../artifacts/output-history/${DateTime.now().microsecondsSinceEpoch}',
      ).absolute..createSync(recursive: true);
      PrototypeState make() => PrototypeState(
        settingsDirectory: dir.path,
        importer: (p, _) async => ImportedTxt(
          path: p,
          sourceId: p,
          revision: 1,
          encoding: 'utf-8',
          lines: 3,
          headings: 1,
        ),
      );
      final first = make();
      addTearDown(first.dispose);
      await first.importBookOutcome(r'D:\history-sample.txt');
      final finished = first.outputs.begin(
        first.currentId,
        'EPUB',
        '${dir.path}/finished.epub',
      );
      await first.outputs.persist(finished);
      first.outputs.update(
        finished,
        'complete',
        terminal: true,
        receipt: {'committed': true, 'output_path': finished.outputPath},
      );
      await first.outputs.historySaved;
      final pending = first.outputs.begin(
        first.currentId,
        'AZW3',
        '${dir.path}/pending.azw3',
      );
      await first.outputs.persist(pending);
      // An unrelated pre-existing output must not promote a pending record.
      File(pending.outputPath).writeAsStringSync('not a validated output');
      final reopened = make();
      addTearDown(reopened.dispose);
      await reopened.outputs.loadHistory();
      expect(reopened.outputs.tasks, hasLength(2));
      expect(reopened.outputs.tasks.first.phase, 'complete');
      expect(reopened.outputs.tasks.first.restored, true);
      expect(reopened.outputs.tasks.last.phase, 'interrupted');
      expect(reopened.queueActive, false);
      expect(reopened.outputs.tasks.last.job, isNull);
      final broken = File('${dir.path}/output-history/broken.json')
        ..writeAsStringSync('{');
      final corrupted = make();
      addTearDown(corrupted.dispose);
      await corrupted.outputs.loadHistory();
      expect(corrupted.outputs.historyStatus, contains('读取失败'));
      expect(broken.readAsStringSync(), '{');
      File('../artifacts/audit-20261004/baseline/evidence/r4r5-output-history.json').writeAsStringSync(
        jsonEncode({
          'passed': true,
          'actual_dll': true,
          'history_directory': dir.path,
          'terminal_record_restored': true,
          'pending_is_unverified_even_when_output_exists': true,
          'no_automatic_restart': true,
          'corruption_visible_and_preserved': true,
          'transaction_revalidation_implemented': false,
        }),
      );
    },
  );
}
