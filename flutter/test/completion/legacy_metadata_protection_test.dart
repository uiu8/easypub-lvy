import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('legacy unknown values and clears survive mapping; explicit override and undo preserve unknown baseline', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('legacy-metadata-')).absolute;
    final original = PrototypeState(settingsDirectory: '${root.path}/settings');
    final originalLibrary = LegacyLibraryAdapter(backend: original);
    final path = '${root.path}/legacy.easypub.json';
    late String id;
    try {
      await originalLibrary.load();
      await originalLibrary.savePatch({'check_after_import': false});
      final source = File('${root.path}/sample.txt')
        ..writeAsStringSync('第一章 开始\n旧项目正文。\n');
      await originalLibrary.importFiles([source.path]);
      id = original.currentId;
      final info = originalLibrary.openBookInformation(id);
      await info.apply(
        await info.preview({'author': '旧项目作者', 'publisher': ''}),
      );
      info.dispose();
      expect((await originalLibrary.saveProject(path)).succeeded, true);
    } finally {
      originalLibrary.dispose();
      original.dispose();
    }
    final data = jsonDecode(File(path).readAsStringSync()) as Map;
    for (final book in data['books'] as List) {
      (book as Map).remove('metadata_origins');
      for (final state in book['production_history']['states'] as List) {
        (state as Map).remove('metadata_origins');
      }
    }
    File(path).writeAsStringSync(jsonEncode(data));
    final oldBytes = File(path).readAsBytesSync();
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      expect((await library.openProject(path)).succeeded, true);
      final mapping = library.openMapping();
      final rules = [
        MappingRule(root.path, {
          'author': {'op': 'set', 'value': '规则作者'},
          'publisher': {'op': 'fill_empty', 'value': '出版社'},
        }),
      ];
      final preview = await mapping.preview(rules, [id]);
      expect(preview.items.single.after['author'], '旧项目作者');
      expect(preview.items.single.after['publisher'], '');
      expect(preview.changedBooks, 0);
      expect(
        (state.production.settings(id)['metadata_origins']
            as Map)['author']['source'],
        'unknown',
      );
      final chosen = await (mapping as MappingOverrideSession).previewOverrides(
        rules,
        [id],
        {
          id: {'author'},
        },
      );
      expect(chosen.items.single.after['author'], '规则作者');
      expect(chosen.items.single.after['publisher'], '');
      await mapping.apply(chosen);
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(state.production.settings(id)['author'], '旧项目作者');
      expect(
        (state.production.settings(id)['metadata_origins']
            as Map)['author']['source'],
        'unknown',
      );
      final saved = '${root.path}/migrated.easypub.json';
      expect((await library.saveProject(saved)).succeeded, true);
      final again = PrototypeState(settingsDirectory: '${root.path}/settings');
      final reopened = LegacyLibraryAdapter(backend: again);
      try {
        await reopened.load();
        expect((await reopened.openProject(saved)).succeeded, true);
        final next = reopened.openMapping();
        final p = await next.preview(rules, [id]);
        expect(p.changedBooks, 0);
      } finally {
        reopened.dispose();
        again.dispose();
      }
      expect(
        File(path).readAsBytesSync(),
        oldBytes,
        reason: 'opening never rewrites the legacy project',
      );
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
