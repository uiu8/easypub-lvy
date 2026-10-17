import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('observe remapping after manual edit and deliberate clear', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = await Directory('../artifacts')
        .createTemp('plan-refresh-mapping-');
    final state = PrototypeState(
      settingsDirectory: '${root.absolute.path}/settings',
    );
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final source = File('${root.absolute.path}/映射审计.txt')
        ..writeAsStringSync('第一章 开始\n合成正文。\n');
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = state.currentId;
      final info = library.openBookInformation(id);
      await info.apply(await info.preview({'author': '手工作者', 'publisher': ''}));
      info.dispose();
      final before = state.production.settings(id);
      final session = library.openMapping();
      final rules = [
        MappingRule(root.absolute.path, {
          'author': {'op': 'set', 'value': '规则作者'},
          'publisher': {'op': 'fill_empty', 'value': '规则出版社'},
        }),
      ];
      final preview = await session.preview(rules, [id]);
      final diff = preview.items.single;
      await session.apply(preview);
      final after = state.production.settings(id);
      final result = {
        'type': 'defect_observation_not_acceptance',
        'before': {
          'author': before['author'],
          'publisher': before['publisher'],
        },
        'preview': {
          'author': diff.after['author'],
          'publisher': diff.after['publisher'],
        },
        'after': {'author': after['author'], 'publisher': after['publisher']},
        'manual_author_overwritten': after['author'] == '规则作者',
        'deliberate_clear_refilled': after['publisher'] == '规则出版社',
        'preview_visible': diff.changed,
        'root': root.absolute.path,
      };
      await File('../artifacts/plan-refresh-20261004-mapping.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      expect(
        after['author'],
        '规则作者',
        reason: 'Observation of remaining provenance gap, not desired behavior',
      );
      expect(after['publisher'], '规则出版社');
      expect(source.readAsStringSync(), '第一章 开始\n合成正文。\n');
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
