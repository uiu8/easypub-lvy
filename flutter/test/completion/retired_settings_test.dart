import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test(
    'old inactive checks migrate without changing active settings or history',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = (await Directory(
        '../artifacts',
      ).createTemp('retired-settings57-')).absolute;
      final settings = Directory('${root.path}/settings')..createSync();
      final old = File('${settings.path}/00000000000000000001.json');
      final original = jsonEncode({
        'schema': 1,
        'revision': 1,
        'parent': null,
        'configuration': {
          'check_chapters': false,
          'check_duplicate_text': true,
          'check_title_length': false,
          'check_after_import': true,
          'automatic_cleanup_pipeline': [],
          'ui_theme': 'night',
        },
      });
      old.writeAsStringSync(original);
      final state = PrototypeState(settingsDirectory: settings.path);
      final library = LegacyLibraryAdapter(backend: state);
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      expect(await library.load(), true);
      expect(state.globalSettingsStatus, contains('旧版无效检查开关已停用'));
      for (final key in [
        'check_chapters',
        'check_duplicate_text',
        'check_title_length',
      ]) {
        expect(state.globalConfiguration.containsKey(key), false);
      }
      expect(await library.savePatch({'reduced_motion': true}), true);
      expect(old.readAsStringSync(), original);
      final restored = PrototypeState(settingsDirectory: settings.path);
      addTearDown(restored.dispose);
      expect(await restored.loadGlobalSettings(), true);
      expect(restored.globalConfiguration['ui_theme'], 'night');
      expect(
        restored.globalConfiguration['automatic_cleanup_pipeline'],
        isEmpty,
      );
      expect(restored.globalConfiguration['check_after_import'], true);
      expect(restored.globalConfiguration['reduced_motion'], true);
      expect(restored.globalSettingsStatus, isNot(contains('旧版无效')));
    },
  );
}
