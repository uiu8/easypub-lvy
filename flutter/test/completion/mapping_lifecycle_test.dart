import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('rule edits, deletion and nonmatching paths restore baseline without changing manual fields', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('mapping-lifecycle-')).absolute;
    final source = File('${root.path}/source.txt')
      ..writeAsStringSync('第一章 开始\n合成正文。\n');
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = state.currentId;
      final initial = state.production.settings(id);
      var mapping = library.openMapping();
      List<MappingRule> rules(String author) => [
        MappingRule(root.path, {
          'author': {'op': 'fill_empty', 'value': author},
          'publisher': {'op': 'set', 'value': '规则出版社'},
          'cover_fit': {'op': 'set', 'value': 'fill'},
        }),
      ];
      await mapping.apply(await mapping.preview(rules('第一版'), [id]));
      expect(state.production.settings(id)['author'], '第一版');
      final origin =
          (state.production.settings(id)['metadata_origins'] as Map)['author']
              as Map;
      expect(origin['rule_id'], rules('第一版').first.id);
      expect(origin['rule_version'], rules('第一版').first.version);

      expect(state.production.settings(id)['cover_fit'], 'fill');
      final repeated = await mapping.preview(rules('第一版'), [id]);
      expect(
        repeated.changedBooks,
        0,
        reason: 'unchanged refresh must be idempotent',
      );
      await mapping.apply(repeated);
      final revised = await mapping.preview(rules('第二版'), [id]);
      expect(
        revised.items.single.after['author'],
        '第二版',
        reason: 'fill_empty uses inherited baseline',
      );
      await mapping.apply(revised);
      final info = library.openBookInformation(id);
      await info.apply(await info.preview({'publisher': ''}));
      info.dispose();
      final explicit = mapping as MappingOverrideSession;
      final inherited = await explicit.previewOverrides(
        rules('第二版'),
        [id],
        {},
        restoreFields: {
          id: {'publisher'},
        },
      );
      expect(inherited.items.single.after['publisher'], '规则出版社');
      expect(
        state.production.settings(id)['publisher'],
        '',
        reason: 'restore remains a preview',
      );
      await mapping.apply(inherited);
      expect(
        (state.production.settings(id)['metadata_origins']
            as Map)['publisher']['source'],
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
      expect(
        (state.production.settings(id)['metadata_origins']
            as Map)['publisher']['source'],
        'manual',
      );
      final withoutRule = await explicit.previewOverrides(
        [],
        [id],
        {},
        restoreFields: {
          id: {'publisher'},
        },
      );
      expect(withoutRule.items.single.after['publisher'], initial['publisher']);
      expect(
        (withoutRule.items.single.after['metadata_origins']
            as Map)['publisher']['source'],
        'imported',
      );
      await mapping.apply(withoutRule);
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {'op': 'undo'},
          }),
        ),
        true,
      );
      await expectLater(
        explicit.previewOverrides(
          rules('第二版'),
          [id],
          {
            id: {'publisher'},
          },
          restoreFields: {
            id: {'publisher'},
          },
        ),
        throwsFormatException,
      );
      final movedPath = '${root.path}/temporarily-offline';
      final originalRule = rules('第二版').single;
      final movedRule = originalRule.revised(movedPath, originalRule.fields);
      final beforeOffline = state.production.settings(id);
      final beforeCursor = state.production.histories[id]!['cursor'];
      await expectLater(
        mapping.preview([movedRule], [id]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('目录规则当前不可访问'),
          ),
        ),
        reason: 'the same rule at an unavailable new path is not deleted',
      );
      expect(state.production.settings(id), beforeOffline);
      expect(state.production.histories[id]!['cursor'], beforeCursor);
      Directory(movedPath).createSync();
      final onlineButUnmatched = await mapping.preview([movedRule], [id]);
      expect(
        onlineButUnmatched.items.single.after['author'],
        initial['author'],
        reason: 'an available nonmatching new path really does release the old rule',
      );
      final removed = await mapping.preview([], [id]);
      expect(removed.items.single.after['author'], initial['author']);
      expect(removed.items.single.after['publisher'], '');
      expect(removed.items.single.after['cover_fit'], initial['cover_fit']);
      expect(
        (removed.items.single.after['layout_origins'] as Map?)?['cover_fit'],
        (initial['layout_origins'] as Map?)?['cover_fit'],
      );
      expect(
        state.production.settings(id)['author'],
        '第二版',
        reason: 'preview is not mutation',
      );
      await mapping.apply(removed);
      expect(
        (state.production.settings(id)['metadata_origins']
            as Map)['author']['source'],
        'imported',
      );
      expect(
        (state.production.settings(id)['metadata_origins']
            as Map)['publisher']['source'],
        'manual',
      );
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(state.production.settings(id)['author'], '第二版');
      final project = '${root.path}/saved.easypub.json';
      expect((await library.saveProject(project)).succeeded, true);
      final reopened = PrototypeState(
        settingsDirectory: '${root.path}/settings',
      );
      final second = LegacyLibraryAdapter(backend: reopened);
      try {
        await second.load();
        expect((await second.openProject(project)).succeeded, true);
        mapping = second.openMapping();
        final unrelated = Directory('${root.path}/unrelated')..createSync();
        final outside = await mapping.preview(
          [
            MappingRule(unrelated.path, {
              'author': {'op': 'set', 'value': '不命中'},
            }),
          ],
          [id],
        );
        expect(outside.items.single.after['author'], initial['author']);
        expect(outside.items.single.after['publisher'], '');
        await mapping.apply(outside);
        final keep = await mapping.preview(
          [
            MappingRule(root.path, {
              'author': {'op': 'keep'},
            }),
          ],
          [id],
        );
        expect(keep.items.single.after['author'], initial['author']);
        await mapping.apply(keep);
      } finally {
        second.dispose();
        reopened.dispose();
      }
      expect(source.readAsStringSync(), '第一章 开始\n合成正文。\n');
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
