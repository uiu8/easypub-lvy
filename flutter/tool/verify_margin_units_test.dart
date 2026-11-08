import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_helpers.dart';

void main() {
  test(
    'mixed em and px margins retain units in defaults and project',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File('../target/release/easypub_bridge.dll').absolute.path,
        ),
      );
      final run = Directory(
        '../artifacts/r5-margin-units/${DateTime.now().microsecondsSinceEpoch}',
      ).absolute..createSync(recursive: true);
      final state = PrototypeState(settingsDirectory: '${run.path}/settings');
      final restored = PrototypeState(
        settingsDirectory: '${run.path}/settings',
      );
      addTearDown(state.dispose);
      addTearDown(restored.dispose);
      expect(await state.loadGlobalSettings(), true);
      final values = {
        'margin_top': 3.0,
        'margin_top_unit': 'px',
        'margin_bottom': 120.0,
        'margin_bottom_unit': 'px',
        'margin_left': 0.5,
        'margin_left_unit': 'em',
        'margin_right': 1.0,
        'margin_right_unit': 'em',
      };
      expect(
        await state.saveGlobalLayout(values, state.globalSettingsToken),
        true,
      );
      final token = state.globalSettingsToken;
      expect(
        await state.saveGlobalLayout({
          ...values,
          'margin_bottom_unit': 'em',
        }, token),
        false,
      );
      expect(state.globalSettingsToken, token);
      final book = File('${run.path}/样书.txt')
        ..writeAsStringSync('第一章 起点\n正文保持');
      await state.importBookOutcome(book.path);
      final id = state.currentId;
      for (final e in values.entries) {
        expect(state.production.settings(id)[e.key], e.value);
      }
      final project = '${run.path}/项目.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      expect(await state.saveGlobalLayout({}, state.globalSettingsToken), true);
      await restored.loadGlobalSettings();
      await restored.openProjectOutcome(project);
      for (final e in values.entries) {
        expect(restored.production.settings(id)[e.key], e.value);
      }
      expect(book.readAsStringSync(), '第一章 起点\n正文保持');
      File('../docs/evidence/r5-margin-units.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'passed_partial': true,
          'values': values,
          'project': project,
          'invalid_unit_value_combination_rejected': true,
          'project_units_preserved_after_global_change': true,
          'not_verified': [
            'legacy configuration automatic mapping',
            'Kindle visual/device',
          ],
        }),
      );
    },
  );
}
