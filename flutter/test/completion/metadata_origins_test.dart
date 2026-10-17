import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';

void main() {
  test('manual values, deliberate clears and same-valued intent survive mapping history and project reopening', () async {
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
      final rules = [
        MappingRule(root.path, {
          'author': {'op': 'set', 'value': '规则作者'},
          'publisher': {'op': 'fill_empty', 'value': '规则出版社'},
          'category': {'op': 'set', 'value': '小说'},
        }),
      ];
      final mapping = library.openMapping();
      final preview = await mapping.preview(rules, [id]);
      expect(preview.items.single.after['author'], '手工作者');
      expect(preview.items.single.after['publisher'], '');
      expect(preview.items.single.after['category'], '小说');
      await mapping.apply(preview);
      expect(
        (state.production.settings(id)['metadata_origins']
            as Map)['category']['source'],
        'folder_rule',
      );
      // Same-valued explicit confirmation changes provenance and adds a history step.
      final cursor = state.production.histories[id]!['cursor'];
      info = library.openBookInformation(id);
      final same = await info.preview({'category': '小说'});
      expect(same.changed, contains('category'));
      await info.apply(same);
      info.dispose();
      expect(state.production.histories[id]!['cursor'], (cursor as int) + 1);
      final changed = [
        MappingRule(root.path, {
          'author': {'op': 'set', 'value': '新作者'},
          'publisher': {'op': 'fill_empty', 'value': '新出版社'},
          'category': {'op': 'set', 'value': '新类别'},
        }),
      ];
      final protected = await mapping.preview(changed, [id]);
      expect(protected.items.single.after['category'], '小说');
      await mapping.apply(protected);
      final override = await (mapping as MappingOverrideSession)
          .previewOverrides(
            changed,
            [id],
            {
              id: {'author'},
            },
          );
      expect(override.items.single.after['author'], '新作者');
      expect(override.items.single.after['publisher'], '');
      expect(override.items.single.after['category'], '小说');
      // A newer preview invalidates the original proposal rather than mutating it.
      await expectLater(mapping.apply(protected), throwsFormatException);
      await mapping.apply(override);
      expect(
        (state.production.settings(id)['metadata_origins']
            as Map)['author']['source'],
        'folder_rule',
      );
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(state.production.settings(id)['author'], '手工作者');
      expect(
        (state.production.settings(id)['metadata_origins']
            as Map)['author']['source'],
        'manual',
      );
      final project = '${root.path}/saved.easypub.json';
      expect((await library.saveProject(project)).succeeded, true);
      final reopened = PrototypeState(
        settingsDirectory: '${root.path}/settings',
      );
      final library2 = LegacyLibraryAdapter(backend: reopened);
      try {
        await library2.load();
        expect((await library2.openProject(project)).succeeded, true);
        final mapping2 = library2.openMapping();
        final again = await mapping2.preview(changed, [id]);
        expect(again.items.single.after['author'], '手工作者');
        expect(again.items.single.after['publisher'], '');
        expect(again.items.single.after['category'], '小说');
        await mapping2.apply(again);
        final converter = LegacyConversionSession(reopened);
        try {
          final plan = await converter.preview(
            ConversionRequest(
              books: [id],
              directory: '${root.path}/output',
              format: 'EPUB',
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(
            plan.previewed,
            true,
            reason: plan.findings.map((f) => f.detail).join('\n'),
          );
          final output = (await converter.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(output.complete, true, reason: output.detail);
          final imported = await readBook(output.path, () => false);
          expect(
            (imported.resourceReport!['metadata'] as Map)['author'],
            '手工作者',
          );
        } finally {
          converter.dispose();
        }
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
