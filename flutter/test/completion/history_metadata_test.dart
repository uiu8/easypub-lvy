import 'dart:io';

import 'package:easypub_desktop/application/metadata_mapping_service.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('history classifies metadata and origin-only changes and preserves undo after reopening', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('metadata-origins-')).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('${root.path}/来源.txt')
        ..writeAsStringSync('第一章 开始\n合成正文。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
      var info = library.openBookInformation(id);
      await info.apply(await info.preview({'author': '手工作者', 'publisher': ''}));
      info.dispose();
      final history = library.openChangeHistory();
      var record = history.records(id).firstWhere((r) => r.domain == '制作');
      expect(record.category, '书籍信息');
      var detail = history.detail(record);
      expect(
        detail.fields.any((f) => f.label.contains('metadata_origins')),
        false,
      );
      expect(
        detail.fields.any((f) => f.label == '作者来源' && f.after == '手工确认'),
        true,
      );
      expect(
        detail.fields.any((f) => f.label == '作者' && f.after == '手工作者'),
        true,
      );
      // Same-valued confirmation must not disappear or be classified as layout.
      info = library.openBookInformation(id);
      await info.apply(
        await info.preview({
          'category': state.production.settings(id)['category'],
        }),
      );
      info.dispose();
      record = history.records(id).firstWhere((r) => r.domain == '制作');
      expect(record.category, '书籍信息');
      detail = history.detail(record);
      expect(
        detail.fields.any((f) => f.label == '类别来源' && f.after == '手工确认'),
        true,
      );
      final mapping = library.openMapping();
      final rules = [
        MappingRule(root.path, {
          'author': {'op': 'set', 'value': '规则作者'},
        }),
      ];
      final preview = await (mapping as MappingOverrideSession)
          .previewOverrides(
            rules,
            [id],
            {
              id: {'author'},
            },
          );
      await mapping.apply(preview);
      record = history.records(id).firstWhere((r) => r.domain == '制作');
      detail = history.detail(record);
      expect(record.category, '书籍信息');
      expect(
        detail.fields.any((f) => f.label == '作者来源' && f.after == '全局目录规则'),
        true,
      );
      expect(
        detail.fields.any(
          (f) =>
              f.label.contains('metadata_origins') ||
              f.label.contains('baseline'),
        ),
        false,
      );
      final project = '${root.path}/history.easypub.json';
      expect((await library.saveProject(project)).succeeded, true);
      final reopened = PrototypeState(
        settingsDirectory: '${root.path}/settings',
      );
      final library2 = LegacyLibraryAdapter(backend: reopened);
      try {
        await library2.load();
        expect((await library2.openProject(project)).succeeded, true);
        final history2 = library2.openChangeHistory();
        final saved = history2.records(id).firstWhere((r) => r.domain == '制作');
        expect(saved.category, '书籍信息');
        await history2.undo(history2.detail(saved));
        expect(reopened.production.settings(id)['author'], '手工作者');
        expect(
          (reopened.production.settings(id)['metadata_origins']
              as Map)['author']['source'],
          'manual',
        );
      } finally {
        library2.dispose();
        reopened.dispose();
      }
      expect(file.readAsStringSync(), '第一章 开始\n合成正文。\n');
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
