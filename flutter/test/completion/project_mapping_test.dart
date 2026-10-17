import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('project rules outrank deeper global matches, fallback and survive reopen without changing globals', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('project-mapping-')).absolute;
    final projectDir = Directory('${root.path}/project')..createSync();
    final child = Directory('${projectDir.path}/child')..createSync();
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final global = library.openMapping();
      await global.saveRules([
        MappingRule(root.path, {
          'author': {'op': 'set', 'value': '全局作者'},
        }),
        MappingRule(child.path, {
          'author': {'op': 'set', 'value': '全局子目录'},
        }),
      ]);
      final globals = state.globalFolderRules;
      final project = library.openMapping();
      final scoped = project as ProjectMappingSession;
      scoped.selectProjectScope(true);
      await project.saveRules([
        MappingRule(projectDir.path, {
          'author': {'op': 'set', 'value': '项目作者'},
        }),
      ]);
      expect(scoped.projectEnabled, true);
      expect(state.globalFolderRules, globals);
      Future<String> add(String path, int number) async {
        File(path).writeAsStringSync('第一章 开始\n合成正文$number。\n');
        expect((await library.importFiles([path])).single.succeeded, true);
        return state.currentId;
      }

      final first = await add('${child.path}/first.txt', 1);
      expect(state.production.settings(first)['author'], '项目作者');
      expect(
        (state.production.settings(first)['metadata_origins']
            as Map)['author']['rule_priority'],
        1,
      );
      final outside = await add('${root.path}/outside.txt', 2);
      expect(state.production.settings(outside)['author'], '全局作者');
      final sameFolderProject = project.rules.single.revised(child.path, {
        'author': {'op': 'set', 'value': '同路径项目'},
      });
      await project.saveRules([sameFolderProject]);
      final preview = await project.preview(project.rules, [first]);
      expect(preview.items.single.after['author'], '同路径项目');
      await project.apply(preview);
      scoped.setProjectEnabled(false);
      final disabled = await project.preview(project.rules, [first]);
      expect(disabled.items.single.after['author'], '全局子目录');
      await project.apply(disabled);
      final third = await add('${child.path}/third.txt', 3);
      expect(state.production.settings(third)['author'], '全局子目录');
      scoped.setProjectEnabled(true);
      final path = '${root.path}/saved.easypub.json';
      expect((await library.saveProject(path)).succeeded, true);
      final restored = PrototypeState(
        settingsDirectory: '${root.path}/settings',
      );
      final reopened = LegacyLibraryAdapter(backend: restored);
      try {
        await reopened.load();
        expect((await reopened.openProject(path)).succeeded, true);
        expect(restored.projectFolderRulesEnabled, true);
        expect(restored.globalFolderRules, globals);
        final file = File('${child.path}/fourth.txt')
          ..writeAsStringSync('第一章 开始\n重开后正文。\n');
        expect(
          (await reopened.importFiles([file.path])).single.succeeded,
          true,
        );
        expect(
          restored.production.settings(restored.currentId)['author'],
          '同路径项目',
        );
        final info = reopened.openBookInformation(restored.currentId);
        await info.apply(await info.preview({'author': '手工作者'}));
        info.dispose();
        final remap = reopened.openMapping();
        final protected = await remap.preview(remap.rules, [
          restored.currentId,
        ]);
        expect(protected.items.single.after['author'], '手工作者');
        expect(restored.globalFolderRules, globals);
      } finally {
        reopened.dispose();
        restored.dispose();
      }
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
