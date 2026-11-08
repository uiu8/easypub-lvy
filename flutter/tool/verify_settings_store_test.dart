import 'package:easypub_desktop/prototype/prototype_state.dart';

import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_helpers.dart';

void main() {
  test('actual configuration storage rejects stale writers and keeps revisions', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final directory = Directory(
      '../artifacts/r5-settings-store/${DateTime.now().microsecondsSinceEpoch}',
    ).absolute;
    Future<Map<String, dynamic>> load() async =>
        jsonDecode(await api.loadSettingsText(directory: directory.path))
            as Map<String, dynamic>;
    Future<Map<String, dynamic>> save(String? token, int size) async =>
        jsonDecode(
          await api.saveSettingsText(
            directory: directory.path,
            expectedToken: token,
            configurationJson: jsonEncode({
              'layout_defaults': {'font_size': size},
              'layout_presets': [],
            }),
          ),
        ) as Map<String, dynamic>;
    final state = PrototypeState(
      settingsDirectory: '${directory.path}/import-settings',
    );
    final reopened = PrototypeState(
      settingsDirectory: '${directory.path}/import-settings',
    );
    addTearDown(state.dispose);
    addTearDown(reopened.dispose);
    expect(await state.loadGlobalSettings(), true);
    expect(
      await state.saveGlobalLayout({
        'font_size': 22.0,
        'visible_toc': true,
      }, null),
      true,
    );
    await directory.create(recursive: true);
    final firstBook = File('${directory.path}/first.txt');
    await firstBook.writeAsString('第一章 起点\n正文');
    await state.importBookOutcome(firstBook.path);
    final firstId = state.currentId;
    expect(state.production.settings(firstId)['font_size'], 22.0);
    expect(state.production.settings(firstId)['visible_toc'], true);
    final oldToken = state.globalSettingsToken;
    expect(await state.saveGlobalLayout({'font_size': 24.0}, oldToken), true);
    expect(state.production.settings(firstId)['font_size'], 22.0);
    expect(await state.saveGlobalLayout({'font_size': 20.0}, oldToken), false);
    await state.importBookOutcome(firstBook.path);
    expect(state.production.settings(firstId)['font_size'], 22.0);
    final secondBook = File('${directory.path}/second.txt');
    await secondBook.writeAsString('第一章 新书\n正文');
    await state.importBookOutcome(secondBook.path);
    expect(state.production.settings(state.currentId)['font_size'], 24.0);
    final project = '${directory.path}/project.easypub.json';
    await state.saveProjectOutcome(project);
    expect(File(project).existsSync(), true, reason: state.projectStatus);
    expect(
      await state.saveGlobalLayout({
        'font_size': 16.0,
      }, state.globalSettingsToken),
      true,
    );
    await reopened.loadGlobalSettings();
    await reopened.openProjectOutcome(project);
    expect(reopened.production.settings(firstId)['font_size'], 22.0);
    expect(reopened.production.settings(state.currentId)['font_size'], 24.0);
    final presetSnapshot = {
      'name': '跨项目小说',
      'values': {'font_size': 20.0},
    };
    expect(
      await state.saveGlobalPresets([
        presetSnapshot,
      ], state.globalSettingsToken),
      true,
    );
    expect(state.globalConfiguration['layout_defaults']['font_size'], 16.0);
    await reopened.loadGlobalSettings();
    expect(reopened.globalConfiguration['layout_presets'], [presetSnapshot]);
    final globalPresetToken = reopened.globalSettingsToken;
    expect(await state.saveGlobalPresets([], state.globalSettingsToken), true);
    expect(
      await reopened.saveGlobalPresets([presetSnapshot], globalPresetToken),
      false,
    );
    expect(reopened.production.settings(firstId)['font_size'], 22.0);
    expect(
      await state.saveGlobalPresets([
        presetSnapshot,
        presetSnapshot,
      ], state.globalSettingsToken),
      false,
    );
    final cleanupPreset = {
      'name': '正文清理',
      'pipeline': [
        {'kind': 'trim_trailing_spaces'},
      ],
    };
    expect(
      await state.saveGlobalCleanupPresets([
        cleanupPreset,
      ], state.globalSettingsToken),
      true,
    );
    expect(state.globalConfiguration['layout_defaults']['font_size'], 16.0);
    await reopened.loadGlobalSettings();
    expect(reopened.globalConfiguration['cleanup_presets'], [cleanupPreset]);
    final cleanupToken = reopened.globalSettingsToken;
    expect(
      await state.saveGlobalLayout({
        'font_size': 18.0,
      }, state.globalSettingsToken),
      true,
    );
    expect(state.globalConfiguration['cleanup_presets'], [cleanupPreset]);
    expect(await reopened.saveGlobalCleanupPresets([], cleanupToken), false);
    expect(
      await state.saveGlobalCleanupPresets([
        cleanupPreset,
        cleanupPreset,
      ], state.globalSettingsToken),
      false,
    );
    final empty = await load();
    expect(empty['revision'], 0);
    expect(
      File('${directory.path}/00000000000000000001.json').existsSync(),
      false,
    );
    final first = await save(null, 20);
    final original = await File('${directory.path}/00000000000000000001.json')
        .readAsBytes();
    final second = await save(first['token'] as String, 24);
    await expectLater(save(first['token'] as String, 18), throwsA(anything));
    expect((await load())['token'], second['token']);
    expect(
      await File('${directory.path}/00000000000000000001.json').readAsBytes(),
      original,
    );
    final resolved = jsonDecode(
      await api.resolveLayoutSettingsText(
        layersJson: jsonEncode({
          'global': second['configuration']['layout_defaults'],
          'book': {'font_size': 18},
        }),
      ),
    ) as Map;
    expect(resolved['values']['font_size'], 18);
    expect(resolved['origins']['font_size'], 'book');
    final third = await save(second['token'] as String, 20);
    expect(third['revision'], 3);
    await File('${directory.path}/.interrupted.tmp').writeAsString('partial');
    expect((await load())['token'], third['token']);
    await File('${directory.path}/00000000000000000003.json')
        .writeAsString('corrupt');
    await expectLater(load(), throwsA(anything));
    await File('../docs/evidence/r5-settings-store.json').writeAsString(
      jsonEncode({
        'passed': true,
        'immutable_history': true,
        'stale_writer_refused': true,
        'partial_stage_ignored': true,
        'corruption_refused': true,
        'layer_resolution': true,
        'user_profile_modified': false,
        'new_import_defaults_and_project_isolation': true,
        'global_presets_cross_session_and_conflict': true,
        'global_cleanup_presets_cross_session_and_conflict': true,
      }),
    );
  });
}
