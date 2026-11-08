import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_helpers.dart';

void main() {
  test('complete bibliographic fields share production project and resource model', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(Platform.environment['EASYPUB_TEST_DLL'] ?? '../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r5-bibliographic/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final state = PrototypeState(), reopened = PrototypeState();
    const values = {
      'translator': '译者甲',
      'isbn': '978-7-000-00000-0',
      'publication_date': '2026-09',
      'publisher': '出版社乙',
      'category': '文学 / 幻想',
      'language': 'zh-CN',
    };
    final a = File('${dir.absolute.path}/甲.txt'),
        b = File('${dir.absolute.path}/乙.txt');
    const body = '第一章 起点\n正文保留。';
    await a.writeAsString(body);
    await b.writeAsString(body);
    try {
      await state.importBookOutcome(a.path);
      final aid = state.currentId;
      await state.importBookOutcome(b.path);
      final bid = state.currentId;
      for (final key in values.keys) {
        expect(state.production.settings(aid)[key], '');
      }
      final preview = await state.production.previewChanges({
        aid: {
          'op': 'patch',
          'fields': {
            for (final entry in values.entries)
              entry.key: {'op': 'set', 'value': entry.value},
          },
        },
      });
      for (final key in values.keys) {
        expect(state.production.settings(aid)[key], '');
      }
      expect(await state.production.confirm(preview), true);
      final copy = await state.production.previewResources(
        aid,
        [bid],
        copyMetadata: true,
        copyCover: false,
        copyTypography: false,
        copyIllustrations: false,
        overwrite: false,
      );
      expect(await state.production.confirm(copy), true);
      for (final id in [aid, bid]) {
        final settings = state.production.settings(id);
        final manifest =
            (await state.production.publicationResources(id))['manifest'] as Map;
        for (final entry in values.entries) {
          expect(settings[entry.key], entry.value);
          expect(manifest[entry.key], entry.value);
        }
      }
      state.folderRules = [
        {
          'folder': dir.absolute.path,
          'fields': {
            'translator': {'op': 'clear'},
            'publisher': {'op': 'fill_empty', 'value': '不覆盖'},
            'category': {'op': 'set', 'value': '新类别'},
          },
        },
      ];
      expect(
        await state.production.confirm(
          await state.previewFolderMapping(state.folderRules, [bid]),
        ),
        true,
      );
      expect(state.production.settings(bid)['translator'], '');
      expect(state.production.settings(bid)['publisher'], values['publisher']);
      expect(state.production.settings(bid)['category'], '新类别');
      final project = '${dir.absolute.path}/项目.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(project);
      expect(reopened.production.settings(bid), state.production.settings(bid));
      expect(reopened.folderRules, state.folderRules);
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            bid: {'op': 'undo'},
          }),
        ),
        true,
      );
      for (final entry in values.entries) {
        expect(reopened.production.settings(bid)[entry.key], entry.value);
      }
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            bid: {'op': 'redo'},
          }),
        ),
        true,
      );
      expect(reopened.production.settings(bid)['translator'], '');
      await expectLater(
        reopened.production.previewChanges({
          bid: {
            'op': 'patch',
            'fields': {
              'isbn': {'op': 'set', 'value': 123},
            },
          },
        }),
        throwsA(anything),
      );
      await expectLater(
        reopened.production.previewChanges({
          bid: {
            'op': 'patch',
            'fields': {
              'translator': {'op': 'set', 'value': '甲' * 2000},
            },
          },
        }),
        throwsA(anything),
      );
      expect(await a.readAsString(), body);
      expect(await b.readAsString(), body);
      await File('../docs/evidence/r5-bibliographic.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'checks': [
            'six fields preview and confirm',
            'batch fill-empty metadata',
            'resource manifest carries all fields',
            'folder rules clear fill-empty set',
            'project config and fields roundtrip',
            'undo redo after reopen',
            'wrong type and oversized value rejected',
            'original TXT unchanged',
          ],
          'not_verified': ['EPUB metadata export', 'reader acceptance'],
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
