import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('folder rules preview confirm undo and project roundtrip', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(Platform.environment['EASYPUB_TEST_DLL'] ?? '../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r5-folder-mapping/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final parent = await Directory('${dir.absolute.path}/books').create();
    final child = await Directory('${parent.path}/author').create();
    final other = await Directory('${dir.absolute.path}/books-other').create();
    final a = File('${child.path}/甲.txt'), b = File('${other.path}/乙.txt');
    await a.writeAsString('第一章 甲\n正文甲');
    await b.writeAsString('第一章 乙\n正文乙');
    final cover = File('${dir.absolute.path}/封面.png');
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgZGIGAAAOAAfXb+R4AAAAAElFTkSuQmCC',
    );
    await cover.writeAsBytes(png);
    final state = PrototypeState(), reopened = PrototypeState();
    try {
      await state.importBookOutcome(a.path);
      final aid = state.currentId;
      await state.importBookOutcome(b.path);
      final bid = state.currentId;
      final beforeA = state.production.settings(aid),
          beforeB = state.production.settings(bid);
      final rules = <Map<String, dynamic>>[
        {
          'folder': parent.path,
          'fields': {
            'author': {'op': 'set', 'value': '父目录作者'},
          },
        },
        {
          'folder': child.path,
          'fields': {
            'author': {'op': 'set', 'value': '子目录作者'},
            'description': {'op': 'clear'},
            'title': {'op': 'fill_empty', 'value': '不覆盖书名'},
            'cover_path': {'op': 'set', 'value': cover.path},
          },
        },
      ];
      state.folderRules = rules;
      final preview = await state.previewFolderMapping(rules, [aid, bid]);
      expect(preview.result['items'][0]['mapping']['candidates'], [1, 0]);
      expect(preview.result['items'][1]['mapping']['winner'], isNull);
      expect(state.production.settings(aid), beforeA);
      expect(await state.production.confirm(preview), true);
      expect(state.production.settings(aid)['author'], '子目录作者');
      expect(state.production.settings(aid)['title'], beforeA['title']);
      expect(state.production.settings(aid)['cover_path'], cover.path);
      expect(state.production.settings(bid), beforeB);
      final after = state.production.settings(aid);
      final project = '${dir.absolute.path}/项目.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(project);
      expect(reopened.folderRules, rules);
      expect(reopened.production.settings(aid), after);
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            aid: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(reopened.production.settings(aid), beforeA);
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            aid: {'op': 'redo'},
          }),
        ),
        true,
      );
      expect(reopened.production.settings(aid), after);
      await expectLater(
        state.previewFolderMapping(
          [
            rules[0],
            {'folder': '${child.path}/..', 'fields': rules[0]['fields']},
          ],
          [aid],
        ),
        throwsA(anything),
      );
      // Missing rule directories must not make an otherwise valid project unusable.
      final offlineRules = <Map<String, dynamic>>[
        {
          'folder': '${dir.absolute.path}/offline',
          'fields': {
            'author': {'op': 'set', 'value': '离线规则'},
          },
        },
      ];
      reopened.folderRules = offlineRules;
      final offlineProject = '${dir.absolute.path}/offline.easypub.json';
      await reopened.saveProjectOutcome(offlineProject);
      expect(
        File(offlineProject).existsSync(),
        true,
        reason: reopened.projectStatus,
      );
      await reopened.openProjectOutcome(offlineProject);
      expect(reopened.folderRules, offlineRules);
      final offlinePreview=await reopened.previewFolderMapping(reopened.folderRules,[aid]);
      final offlineItem=(offlinePreview.result['items'] as List).single as Map;
      expect((offlineItem['mapping'] as Map)['winner'],isNull);
      expect((offlineItem['mapping'] as Map)['unavailable'],[0]);
      expect(offlineItem['changed_fields'],isEmpty);
      expect(await reopened.production.confirm(offlinePreview),true);
      expect(reopened.production.settings(aid),after);
      reopened.folderRules = [
        {
          'folder': parent.path,
          'fields': {
            'author': {'op': 'fill_empty', 'value': 123},
          },
        },
      ];
      final invalidProject = '${dir.absolute.path}/invalid.easypub.json';
      await reopened.saveProjectOutcome(invalidProject);
      expect(File(invalidProject).existsSync(), false);
      reopened.folderRules = rules;
      final pending = await reopened.previewFolderMapping(rules, [aid]);
      await cover.writeAsString('changed');
      expect(await reopened.production.confirm(pending), false);
      expect(reopened.production.settings(aid), after);
      await cover.writeAsBytes(png);
      expect(await a.readAsString(), '第一章 甲\n正文甲');
      expect(await b.readAsString(), '第一章 乙\n正文乙');
      await File('../docs/evidence/r5-folder-mapping.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'checks': [
            'specific subdirectory and component boundary',
            'preview does not apply',
            'set fill-empty clear and cover',
            'project settings roundtrip undo redo',
            'folder rule configuration project roundtrip',
            'canonical duplicate rejected',
            'changed cover rejected',
            'sources untouched',
            'offline rules survive project open but application rejects missing directory',
            'invalid fill-empty value refuses project save',
          ],
          'not_verified': ['rule editor UI', 'extended bibliographic fields'],
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
