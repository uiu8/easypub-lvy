import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('migrated builtin intent produces explicit scoped cleanup', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final oracle = {
      'cases': [
        {
          'options': {
            'RemoveDuplicateChapterTitles': true,
            'CollapseBlankLines': true,
          },
          'input': '第一章 甲\n第一章 甲\n正文\n\n\n',
          'expected': '第一章 甲\n正文\n\n',
        },
        {
          'options': {
            'RemoveRepeatedHeaders': true,
            'ApplyOcrCorrections': true,
          },
          'input': '第一章 甲\n第1页\n天 地\n',
          'expected': '第一章 甲\n第1页\n天地\n',
        },
        {
          'options': {'NormalizeFullWidthSpaces': true},
          'input': '第一章 甲\n　　甲　　乙  \n',
          'expected': '第一章 甲\n　　甲 乙\n',
        },
        {
          'options': {'ChineseVariant': 1},
          'input': '第一章 甲\n圖書\n',
          'expected': '第一章 甲\n图书\n',
        },
      ],
    };
    final run = Directory(
      '../artifacts/r5-legacy-builtins/${DateTime.now().microsecondsSinceEpoch}',
    ).absolute..createSync(recursive: true);
    final outputs = <String>[];
    for (final (index, c) in (oracle['cases'] as List).indexed) {
      final state = PrototypeState();
      addTearDown(state.dispose);
      final config = File('${run.path}/配置$index.json')
        ..writeAsStringSync(
          jsonEncode({
            'LastProfile': {
              'Options': {'TextCleanup': c['options']},
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
        ..writeAsStringSync(c['input'] as String);
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
      expect(output.readAsStringSync(), c['expected']);
      expect(file.readAsBytesSync(), original);
      expect(config.readAsBytesSync(), configBytes);
      expect(
        File('${receipt['transaction_dir']}/source-backup.bin')
            .readAsBytesSync(),
        original,
      );
      outputs.add(output.path);
    }
    File('../docs/evidence/r5-legacy-builtins.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'passed_partial': true,
        'oracle': oracle,
        'outputs': outputs,
        'checks': [
          'duplicate titles and blank lines',
          'page header preserved without removal consent',
          'OCR scoped to body',
          'fullwidth spacing and phrase dictionary conversion',
          'actual DLL preview/commit and original backup',
        ],
        'not_verified': [
          'all builtin combinations',
          'multiline migration',
          'advertisement and builtin overrides',
          'complete legacy cleanup migration',
        ],
      }),
    );
  });
}
