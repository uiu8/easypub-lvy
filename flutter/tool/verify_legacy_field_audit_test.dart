import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_helpers.dart';

void main() {
  test('legacy unit and range gaps remain explicit in actual DLL', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final run = Directory(
      '../artifacts/r5-legacy-field-audit/${DateTime.now().microsecondsSinceEpoch}',
    ).absolute..createSync(recursive: true);
    final state = PrototypeState(settingsDirectory: '${run.path}/settings');
    addTearDown(state.dispose);
    final samples = <String, String>{
      'xml': '<EasyPubConfig><RecentOptions><lineheight>120</lineheight><fontsize>110</fontsize><top>0</top><pagetopunit>0</pagetopunit><left>3</left><pageleftunit>0</pageleftunit><margintop>0.6</margintop><margintopunit>2</margintopunit></RecentOptions><AdvancedOptions/></EasyPubConfig>',
      'json': jsonEncode({
        'LastProfile': {
          'Options': {
            'LineHeightPercent': 120,
            'FontSizePercent': 110,
            'PageMarginTopPx': 0,
            'PageMarginLeftPx': 3,
            'AdditionalCss': 'p { color: #123456; }',
            'CoverImagePath': 'synthetic-cover.png',
            'Illustrations': [],
            'Metadata': {'Title': '合成配置样书'},
            'TextEncoding': 0,
            'RemoveBlankLines': true,
            'AddFullWidthIndent': true,
            'FullWidthIndentCount': 2,
            'TocHierarchy': {
              'IncludeHtmlTocPage': true,
              'IncludeChapterTopNavigation': true,
            },
          },
        },
      }),
    };
    final reports = <String, dynamic>{};
    for (final entry in samples.entries) {
      final file = File('${run.path}/config.${entry.key}')
        ..writeAsStringSync(entry.value);
      final original = file.readAsBytesSync();
      final report = await state.inspectLegacySettings(file.path);
      expect(file.readAsBytesSync(), original);
      expect(Directory(state.settingsDirectory!).existsSync(), false);
      final proposed = (report['report'] as Map)['proposed_layout'] as Map;
      expect(proposed['line_height'], 1.2);
      expect(proposed.containsKey('font_size'), false);
      expect(proposed['margin_left'], 3.0);
      expect(proposed['margin_left_unit'], 'px');
      reports[entry.key] = report;
    }
    expect(await state.loadGlobalSettings(), true);
    expect(
      await state.saveGlobalLayout({
        'line_height': 1.2,
      }, state.globalSettingsToken),
      true,
    );
    final book = File('${run.path}/样书.txt')..writeAsStringSync('第一章 起点\n正文保持');
    await state.importBookOutcome(book.path);
    final id = state.currentId;
    expect(state.production.settings(id)['line_height'], 1.2);
    final project = '${run.path}/项目.easypub.json';
    await state.saveProjectOutcome(project);
    expect(File(project).existsSync(), true, reason: state.projectStatus);
    expect(
      await state.saveGlobalLayout({
        'line_height': 1.8,
      }, state.globalSettingsToken),
      true,
    );
    final restored = PrototypeState(settingsDirectory: state.settingsDirectory);
    addTearDown(restored.dispose);
    await restored.loadGlobalSettings();
    await restored.openProjectOutcome(project);
    expect(restored.production.settings(id)['line_height'], 1.2);
    File('../docs/evidence/r5-legacy-field-audit.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'read_only_probe_passed': true,
        'line_height_1_2_new_book_and_project_roundtrip': true,
        'synthetic_config_directory': run.path,
        'reports': reports,
        'migration_complete': false,
        'next_gap': 'Legacy 120 percent line height is now supported; pixel margins still need preserved units.',
      }),
    );
  });
}
