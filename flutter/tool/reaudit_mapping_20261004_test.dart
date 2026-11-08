import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_mapping_session.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';

void main() {
  testWidgets('observe saved mapping on import and settings reload', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final base = Directory('../artifacts/reaudit-20261004-mapping')
        ..createSync(recursive: true);
      final root = base.createTempSync('run-').absolute;
      final settings = '${root.path}/settings';
      final state = PrototypeState(settingsDirectory: settings);
      final library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      String? emptyError;
      try {
        library.openMapping();
      } catch (e) {
        emptyError = e.toString();
      }
      final seed = File('${root.path}/已有样书.txt')
        ..writeAsStringSync('第一章 测试\n合成测试正文。\n');
      expect((await library.importFiles([seed.path])).single.succeeded, true);
      final mapping = LegacyMappingSession(state);
      mapping.saveRules([
        MappingRule(root.path, {
          'publisher': {'op': 'set', 'value': '合成映射出版社'},
        }),
      ]);
      final source = File('${root.path}/映射样书.txt')
        ..writeAsStringSync('第一章 初见\n合成正文。\n');
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final publisher = state.production.settings(state.currentId)['publisher'];
      final restored = PrototypeState(settingsDirectory: settings);
      final second = LegacyLibraryAdapter(backend: restored);
      await second.load();
      final result = {
        'empty_library_mapping_error': emptyError,
        'saved_rules_in_session': mapping.rules.length,
        'publisher_after_import': publisher,
        'automatic_mapping_applied': publisher == '合成映射出版社',
        'rules_in_fresh_workspace': restored.folderRules.length,
        'project_saved': false,
        'note':
            'Observation probe: expected defects are NOT repair acceptance.',
      };
      File(
        '../artifacts/reaudit-20261004-mapping.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
      second.dispose();
      restored.dispose();
      library.dispose();
      state.dispose();
      expect(emptyError, contains('No element'));
      expect(result['automatic_mapping_applied'], false);
      expect(result['rules_in_fresh_workspace'], 0);
    });
  });
}
