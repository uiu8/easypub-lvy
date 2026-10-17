import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('migrated advertisement preserves protection and requires selection', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final dir = Directory(
      '../artifacts/r5-legacy-advertisement/${DateTime.now().microsecondsSinceEpoch}',
    ).absolute..createSync(recursive: true);
    final state = PrototypeState();
    addTearDown(state.dispose);
    final config = File('${dir.path}/旧配置.json')
      ..writeAsStringSync(
        jsonEncode({
          'LastProfile': {
            'Options': {
              'TextCleanup': {
                'RemoveSiteNotices': true,
                'Advertisement': {
                  'Pattern': r'^AD:',
                  'IsRegex': true,
                  'PreservePattern': '对白',
                  'PreserveIsRegex': false,
                  'UsePromotionHeuristics': false,
                  'MatchKeywords': ['推广'],
                  'PreserveKeywords': ['引用'],
                },
              },
            },
          },
        }),
      );
    final configBytes = config.readAsBytesSync();
    final report = await state.inspectLegacySettings(config.path);
    final pipeline =
        ((((report['report'] as Map)['proposed_cleanup_presets'] as List).single
                as Map)['pipeline']
            as List);
    const original =
        '第一章 甲\r\nad: 普通广告\r\nAD: 正文对白\r\n推广：引用\r\n推广：链接\r\n正文。\r\n';
    final input = File('${dir.path}/原稿.txt')..writeAsStringSync(original);
    final sourceBytes = input.readAsBytesSync();
    await state.importBookOutcome(input.path);
    final source = state.current.source!;
    final settings = <String, dynamic>{'kind': 'cleanup', 'pipeline': pipeline};
    Future<Map> preview(Map value) async => jsonDecode(
      await api.previewRepairPlanText(
        sourceId: source.sourceId,
        revision: source.revision,
        selectedJson: jsonEncode(value),
      ),
    ) as Map;
    final initial = await preview(settings);
    expect(initial['change_count'], 0);
    final candidates = (initial['candidates'] as List).cast<Map>();
    expect(candidates.map((c) => c['source_line']).toList(), [2, 3, 4, 5]);
    for (final line in [3, 4]) {
      expect(
        candidates.singleWhere((c) => c['source_line'] == line)['selectable'],
        false,
      );
      await expectLater(
        preview({
          ...settings,
          'remove_lines': [line],
        }),
        throwsA(anything),
      );
    }
    final outputs = <String>[];
    for (final selected in [false, true]) {
      final request = {
        ...settings,
        if (selected) 'remove_lines': [2, 5],
      };
      final plan = await preview(request);
      final output = File('${dir.path}/${selected ? '明确排除' : '未选择'}.txt');
      if (!selected) {
        expect(plan['change_count'], 0);
        await expectLater(
          api.commitRepairOutputText(
            sourceId: source.sourceId,
            revision: source.revision,
            sourcePath: input.path,
            outputPath: output.path,
            selectedJson: jsonEncode(request),
            planId: plan['plan_id'],
            confirmed: true,
          ),
          throwsA(anything),
        );
        expect(output.existsSync(), false);
        expect(input.readAsBytesSync(), sourceBytes);
        continue;
      }
      final receipt = jsonDecode(
        await api.commitRepairOutputText(
          sourceId: source.sourceId,
          revision: source.revision,
          sourcePath: input.path,
          outputPath: output.path,
          selectedJson: jsonEncode(request),
          planId: plan['plan_id'],
          confirmed: true,
        ),
      ) as Map;
      expect(
        output.readAsStringSync(),
        selected ? '第一章 甲\r\nAD: 正文对白\r\n推广：引用\r\n正文。\r\n' : original,
      );
      expect(input.readAsBytesSync(), sourceBytes);
      expect(config.readAsBytesSync(), configBytes);
      expect(
        File('${receipt['transaction_dir']}/source-backup.bin')
            .readAsBytesSync(),
        sourceBytes,
      );
      outputs.add(output.path);
    }
    File('../docs/evidence/r5-legacy-advertisement.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'passed_partial': true,
        'outputs': outputs,
        'checks': [
          'actual DLL legacy migration',
          'case insensitive pattern and keyword candidates',
          'literal and keyword preservation wins',
          'preserved selection rejected',
          'no selection gives zero changes and refuses no-op output',
          'explicit selection removes only selected candidates',
          'CRLF and original/config/backup bytes preserved',
        ],
        'not_verified': [
          'custom builtin overrides',
          'all heuristic differences',
          'complete legacy migration',
          'packaged executable',
        ],
      }),
    );
  });
}
