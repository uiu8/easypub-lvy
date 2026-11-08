import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_helpers.dart';

void main() {
  test('legacy overrides preserve default disablement, shared order and parent gate', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final run = Directory(
      '../artifacts/r5-legacy-overrides/${DateTime.now().microsecondsSinceEpoch}',
    ).absolute..createSync(recursive: true);
    Map rule(int order, String from, String to, bool enabled) => {
      'Name': '替换$order',
      'Pattern': from,
      'Replacement': to,
      'Enabled': enabled,
      'Scope': 1,
      'Order': order,
      'IsRegex': false,
      'IgnoreCase': false,
      'Multiline': false,
    };
    final config = File('${run.path}/旧设置.json')
      ..writeAsStringSync(
        jsonEncode({
          'LastProfile': {
            'Options': {
              'TextCleanup': {
                'RemoveInvisibleCharacters': true,
                'CollapseBlankLines': false,
                'BuiltinOverrides': {
                  'RemoveInvisibleCharacters': {
                    'UseDefaultAlgorithm': false,
                    'Rules': [rule(1, '甲', '乙', true)],
                  },
                  'CollapseBlankLines': {
                    'UseDefaultAlgorithm': true,
                    'Rules': [rule(3, '丙', '丁', true)],
                  },
                },
                'CustomRules': [rule(2, '乙', '丙', true)],
                'ExcludedChangeKeys': ['old-book-coordinate'],
              },
            },
          },
        }),
      );
    final originalConfig = config.readAsBytesSync();
    final state = PrototypeState(settingsDirectory: '${run.path}/settings');
    final restored = PrototypeState(settingsDirectory: '${run.path}/settings');
    addTearDown(state.dispose);
    addTearDown(restored.dispose);
    final report = await state.inspectLegacySettings(config.path);
    final preset = Map<String, dynamic>.from(
      ((report['report'] as Map)['proposed_cleanup_presets'] as List).single
          as Map,
    );
    expect(Directory('${run.path}/settings').existsSync(), false);
    expect(await state.loadGlobalSettings(), true);
    final oldToken = state.globalSettingsToken;
    expect(
      await state.saveGlobalMigrationWithCleanup({}, [], [preset], oldToken),
      true,
    );
    expect(
      await state.saveGlobalMigrationWithCleanup({}, [], [preset], oldToken),
      false,
    );
    final token = state.globalSettingsToken;
    expect(
      await state.saveGlobalMigrationWithCleanup(
        {'font_size': 22.0},
        [],
        [preset, preset],
        token,
      ),
      false,
    );
    expect(await restored.loadGlobalSettings(), true);
    expect(restored.globalSettingsToken, token);
    expect(restored.globalConfiguration['cleanup_presets'], [preset]);
    expect(restored.globalConfiguration['layout_defaults'], isEmpty);
    final file = File('${run.path}/原稿.txt')
      ..writeAsStringSync('第一章 甲\n甲字\u200b\n\n\n');
    final original = file.readAsBytesSync();
    await restored.importBookOutcome(file.path);
    final id = restored.currentId, source = restored.current.source!;
    expect(restored.cleanup.drafts[id], isNull);
    final request = {'kind': 'cleanup', 'pipeline': preset['pipeline']};
    final preview = jsonDecode(
      await api.previewRepairPlanText(
        sourceId: source.sourceId,
        revision: source.revision,
        selectedJson: jsonEncode(request),
      ),
    ) as Map;
    await restored.cleanup.saveSettings(id, request);
    final project = '${run.path}/清理.easypub.json';
    await restored.saveProjectOutcome(project);
    expect(File(project).existsSync(), true, reason: restored.projectStatus);
    final reopened = PrototypeState();
    addTearDown(reopened.dispose);
    await reopened.openProjectOutcome(project);
    expect(reopened.cleanup.drafts[id], restored.cleanup.drafts[id]);
    final output = File('${run.path}/副本.txt');
    final receipt = jsonDecode(
      await api.commitRepairOutputText(
        sourceId: source.sourceId,
        revision: source.revision,
        sourcePath: file.path,
        outputPath: output.path,
        selectedJson: jsonEncode(request),
        planId: preview['plan_id'],
        confirmed: true,
      ),
    ) as Map;
    expect(output.readAsStringSync(), '第一章 甲\n丙字\u200b\n\n\n');
    expect(file.readAsBytesSync(), original);
    expect(
      File('${receipt['transaction_dir']}/source-backup.bin').readAsBytesSync(),
      original,
    );
    expect(config.readAsBytesSync(), originalConfig);
    File('../docs/evidence/r5-legacy-overrides.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'passed_partial': true,
        'output': output.path,
        'checks': [
          'read-only report',
          'preserve order scope and disabled state',
          'override and ordinary rules share numeric ordering',
          'disabled default leaves invisible character intact',
          'disabled parent preserves blank lines and disables child replacement',
          'cross-session preset without automatic application',
          'stale and duplicate saves rejected atomically',
          'project cleanup restored',
          'exact body-only output and source/backup unchanged',
        ],
        'not_verified': [
          'regex and multiline migration',
          'all override and builtin combinations',
          'complete legacy cleanup migration',
        ],
      }),
    );
  });
}
