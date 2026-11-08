import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'migrated regex replacements agree with independent dotnet examples',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File(
            Platform.environment['EASYPUB_TEST_DLL'] ??
                '../target/release/easypub_bridge.dll',
          ).absolute.path,
        ),
      );
      final oracle = jsonDecode(
        File('../samples/legacy-regex-oracle.json')
            .readAsStringSync()
            .replaceFirst('\uFEFF', ''),
      ) as Map;
      final run = Directory(
        '../artifacts/r5-legacy-regex/${DateTime.now().microsecondsSinceEpoch}',
      ).absolute..createSync(recursive: true);
      final outputs = <String>[];
      for (final (index, c) in (oracle['cases'] as List).indexed) {
        final state = PrototypeState();
        addTearDown(state.dispose);
        final config = File('${run.path}/配置$index.json')
          ..writeAsStringSync(
            jsonEncode({
              'LastProfile': {
                'Options': {
                  'TextCleanup': {
                    'CustomRules': [
                      {
                        'Name': '正则',
                        'Pattern': c['pattern'],
                        'Replacement': c['replace'],
                        'IsRegex': true,
                        'IgnoreCase': c['ignore_case'],
                        'Multiline': false,
                        'Scope': 1,
                        'Enabled': true,
                        'Order': 0,
                      },
                    ],
                  },
                },
              },
            }),
          );
        final configBytes = config.readAsBytesSync();
        final report = await state.inspectLegacySettings(config.path);
        final pipeline =
            (((report['report'] as Map)['proposed_cleanup_presets'] as List)
                    .single
                as Map)['pipeline'];
        final file = File('${run.path}/原稿$index.txt')
          ..writeAsStringSync('第一章 标题\n${c['input']}\n');
        final original = file.readAsBytesSync();
        await state.importBookOutcome(file.path);
        final source = state.current.source!;
        final request = jsonEncode({'kind': 'cleanup', 'pipeline': pipeline});
        final preview = jsonDecode(
          await api.previewRepairPlanText(
            sourceId: source.sourceId,
            revision: source.revision,
            selectedJson: request,
          ),
        ) as Map;
        final output = File('${run.path}/副本$index.txt');
        final receipt = jsonDecode(
          await api.commitRepairOutputText(
            sourceId: source.sourceId,
            revision: source.revision,
            sourcePath: file.path,
            outputPath: output.path,
            selectedJson: request,
            planId: preview['plan_id'],
            confirmed: true,
          ),
        ) as Map;
        expect(output.readAsStringSync(), '第一章 标题\n${c['expected']}\n');
        expect(file.readAsBytesSync(), original);
        expect(config.readAsBytesSync(), configBytes);
        expect(
          File('${receipt['transaction_dir']}/source-backup.bin')
              .readAsBytesSync(),
          original,
        );
        outputs.add(output.path);
      }
      File('../docs/evidence/r5-legacy-regex.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'passed_partial': true,
          'oracle': oracle,
          'outputs': outputs,
          'checks': [
            'mixed named and numbered captures',
            'whole-match and dollar/literal substitutions',
            'case-insensitive regex',
            'literal backslash replacement unchanged',
            'actual DLL preview/commit and original backup',
          ],
          'not_verified': [
            'all dotnet regex semantics',
            'multiline migration',
            'context replacement tokens',
            'complete legacy cleanup migration',
          ],
        }),
      );
    },
  );
}
