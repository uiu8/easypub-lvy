import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('all eleven legacy options preview apply and persist independently through real DLL', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final presets = (jsonDecode(await api.cleanupPresetsText()) as List)
        .cast<Map>();
    final choices = presets.where((p) => p['legacy_option'] != null).toList();
    expect(choices.length, 11);
    expect(choices.map((p) => p['legacy_option']).toSet().length, 11);
    expect(presets.any((p) => p['id'] == 'typography-v1'), true);
    final root = (await Directory(
      '../artifacts',
    ).createTemp('legacy-options56-')).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    const raw =
        '第1章 开始\n这 是正文,标点。　　后段\n不可见\u200b文字　空白  \n\n\n广告：下载小说\n第 12 页\n第二章 后续\n第二章 后续\n他走过长长的街道来到河边终于看见\n了远方的灯火。\n';
    final expected = <String, dynamic>{};
    for (final preset in choices) {
      final file = File('${root.path}/${preset['legacy_option']}.txt')
        ..writeAsStringSync(raw);
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = library.books.value.last.id;
      final session = library.openCleanup(id);
      try {
        final preview = await session.preview(
          jsonEncode({'kind': 'cleanup', 'pipeline': preset['rules']}),
        );
        expect(
          preview.total + preview.candidateTotal,
          greaterThan(0),
          reason: '${preset['legacy_option']}',
        );
        if ([
          'RemoveSiteNotices',
          'RemoveRepeatedHeaders',
        ].contains(preset['legacy_option'])) {
          expect(preview.total, 0);
          expect(preview.candidateTotal, greaterThan(0));
        }
        await session.apply(preview);
        expect(jsonDecode(session.settings)['pipeline'], preset['rules']);
        expected[id] = preset['rules'];
        expect(file.readAsStringSync(), raw);
      } finally {
        session.dispose();
      }
    }
    final project = '${root.path}/options.easypub.json';
    expect((await library.saveProject(project)).succeeded, true);
    final restored = PrototypeState(settingsDirectory: '${root.path}/settings');
    final reopened = LegacyLibraryAdapter(backend: restored);
    addTearDown(() {
      reopened.dispose();
      restored.dispose();
    });
    await reopened.load();
    expect((await reopened.openProject(project)).succeeded, true);
    for (final entry in expected.entries) {
      final session = reopened.openCleanup(entry.key);
      try {
        expect(jsonDecode(session.settings)['pipeline'], entry.value);
      } finally {
        session.dispose();
      }
    }
    File('${root.path}/evidence.json').writeAsStringSync(
      jsonEncode({
        'options': choices.map((p) => p['legacy_option']).toList(),
        'sourceUnchanged': true,
        'savedReopened': true,
        'project': project,
      }),
    );
  });
}
