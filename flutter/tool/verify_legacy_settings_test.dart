import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_helpers.dart';

void main() {
  test('actual legacy read and explicit configuration commit', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final dir = Directory(
      '../artifacts/r5-legacy/${DateTime.now().microsecondsSinceEpoch}',
    ).absolute..createSync(recursive: true);
    final source = File('${dir.path}/config.xml');
    const text =
        '<EasyPubConfig><RecentOptions><indent>3</indent><lineheight>180</lineheight><fontsize>110</fontsize></RecentOptions><AdvancedOptions><kindlegenoption>not executed</kindlegenoption></AdvancedOptions></EasyPubConfig>';
    source.writeAsStringSync(text);
    final state = PrototypeState(settingsDirectory: '${dir.path}/settings');
    addTearDown(state.dispose);
    final result = await state.inspectLegacySettings(source.path);
    expect(Directory(state.settingsDirectory!).existsSync(), false);
    expect((result['report'] as Map)['proposed_layout'], {
      'paragraph_indent': 3.0,
      'line_height': 1.8,
    });
    expect(await state.loadGlobalSettings(), true);
    final token = state.globalSettingsToken;
    expect(
      await state.saveGlobalLayout({'paragraph_indent': 3.0}, token),
      true,
    );
    expect(
      await state.saveGlobalLayout({'paragraph_indent': 1.0}, token),
      false,
    );
    expect(await state.loadGlobalSettings(), true);
    expect(state.globalConfiguration['layout_defaults'], {
      'paragraph_indent': 3.0,
    });
    expect(source.readAsStringSync(), text);
    final jsonFile = File('${dir.path}/app-settings.json');
    final jsonText = jsonEncode({
      'LastProfile': {
        'Options': {'TextAlignment': 3, 'FontSizePercent': 110},
      },
      'Presets': [
        {
          'Name': '旧排版',
          'Profile': {
            'Options': {
              'TextAlignment': 4,
              'TocHierarchy': {'IncludeHtmlTocPage': false},
            },
          },
        },
      ],
      'TextEditorPath': 'never execute',
    });
    jsonFile.writeAsStringSync(jsonText);
    final jsonResult = await state.inspectLegacySettings(jsonFile.path);
    final report = jsonResult['report'] as Map;
    expect(report['proposed_layout'], {'text_alignment': 'center'});
    final preset = (report['proposed_presets'] as List).single as Map;
    expect(preset['values'], {'text_alignment': 'right', 'visible_toc': false});
    final candidate = {'name': preset['name'], 'values': preset['values']};
    expect(
      await state.saveGlobalMigration(
        {'paragraph_indent': 3.0, 'text_alignment': 'center'},
        [candidate],
        state.globalSettingsToken,
      ),
      true,
    );
    final committedToken = state.globalSettingsToken;
    expect(
      await state.saveGlobalMigration(
        {'paragraph_indent': 0.0},
        [candidate, candidate],
        committedToken,
      ),
      false,
    );
    expect(await state.loadGlobalSettings(), true);
    expect(state.globalSettingsToken, committedToken);
    expect(state.globalConfiguration['layout_defaults'], {
      'paragraph_indent': 3.0,
      'text_alignment': 'center',
    });
    expect(state.globalConfiguration['layout_presets'], [candidate]);
    expect(jsonFile.readAsStringSync(), jsonText);
    File('../docs/evidence/r5-legacy-settings.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'passed': true,
        'source_unchanged': true,
        'read_did_not_create_settings': true,
        'explicit_subset_saved': true,
        'stale_write_rejected': true,
        'report': result,
        'json_report': jsonResult,
        'json_source_unchanged': true,
        'duplicate_preset_commit_atomic': true,
        'scope':
            'Synthetic XML and isolated configuration; no personal settings',
      }),
    );
  });
}
