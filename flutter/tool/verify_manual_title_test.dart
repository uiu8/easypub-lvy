import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'real DLL title edit preserves source, body, newlines and backup',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File('build/windows/x64/runner/Release/easypub_bridge.dll')
              .absolute
              .path,
        ),
      );
      final run = await Directory(
        '../artifacts/r4-manual-title/${DateTime.now().microsecondsSinceEpoch}',
      ).create(recursive: true);
      final source = File('${run.absolute.path}/原稿.txt');
      const original = '第一章 原题\r\n正文甲\n第二章 续\r正文乙';
      await source.writeAsString(original);
      final imported = await readTxt(source.path, () => false);
      String selection(String title) => jsonEncode({
        'kind': 'rename_title',
        'source_line': 1,
        'title': title,
      });
      final request = selection('第一章 修订题');
      final plan = jsonDecode(
        await api.previewRepairPlanText(
          sourceId: imported.sourceId,
          revision: imported.revision,
          selectedJson: request,
        ),
      ) as Map<String, dynamic>;
      final output = File('${run.absolute.path}/副本.txt');
      Future<String> commit(String selected, bool confirmed) =>
          api.commitRepairOutputText(
            sourceId: imported.sourceId,
            revision: imported.revision,
            sourcePath: source.path,
            outputPath: output.path,
            selectedJson: selected,
            planId: plan['plan_id'] as String,
            confirmed: confirmed,
          );
      await expectLater(commit(request, false), throwsA(anything));
      await expectLater(commit(selection('第一章 未预览'), true), throwsA(anything));
      expect(await output.exists(), false);
      final receipt =
          jsonDecode(await commit(request, true)) as Map<String, dynamic>;
      expect(receipt['committed'], true);
      expect(receipt['source_unchanged'], true);
      expect(receipt['recheck'], isNotNull);
      expect(await output.readAsString(), '第一章 修订题\r\n正文甲\n第二章 续\r正文乙');
      expect(await source.readAsString(), original);
      expect(
        await File('${receipt['transaction_dir']}/source-backup.bin')
            .readAsBytes(),
        await source.readAsBytes(),
      );
      await expectLater(commit(request, true), throwsA(anything));
      await File('../docs/evidence/r4-manual-title.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'receipt': receipt,
          'checks': [
            'exact mixed-newline output',
            'source unchanged',
            'backup byte equality',
            'confirmation required',
            'changed plan rejected',
            'existing output rejected',
          ],
        }),
      );
    },
  );
}
