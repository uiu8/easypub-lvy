import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('presets are explicit snapshots, preserve identities and reopen with history', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r5-layout-presets/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final state = PrototypeState();
    final reopened = PrototypeState();
    try {
      final ids = <String>[];
      for (final name in ['甲', '乙']) {
        final f = File('${dir.absolute.path}/$name.txt');
        await f.writeAsString('第一章 开始\n正文$name');
        await state.importBookOutcome(f.path);
        ids.add(state.currentId);
      }
      final initialSize = state.production.settings(ids.first)['font_size'];
      final layers = <String, dynamic>{
        'global': {'font_size': 24.0, 'visible_toc': true},
        'preset': {'font_size': 22.0},
        'book': {'font_size': 18.0, 'visible_toc': false},
      };
      final layered = await state.production.previewChanges({
        ids.first: {'op': 'apply_layout_layers', 'layers': layers},
      });
      expect(state.production.settings(ids.first)['font_size'], initialSize);
      expect(await state.production.confirm(layered), true);
      expect(state.production.settings(ids.first)['font_size'], 18.0);
      expect(state.production.settings(ids.first)['visible_toc'], false);
      layers['book'] = <String, dynamic>{};
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            ids.first: {'op': 'apply_layout_layers', 'layers': layers},
          }),
        ),
        true,
      );
      expect(state.production.settings(ids.first)['font_size'], 22.0);
      expect(state.production.settings(ids.first)['visible_toc'], true);
      layers['global'] = {'font_size': 26.0};
      expect(state.production.settings(ids.first)['font_size'], 22.0);
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            ids.first: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(state.production.settings(ids.first)['font_size'], 18.0);
      await expectLater(
        state.production.previewChanges({
          ids.first: {
            'op': 'apply_layout_layers',
            'layers': {
              'global': {'font_size': 99},
              'book': {'font_size': 18},
            },
          },
        }),
        throwsA(anything),
      );
      final before = {for (final id in ids) id: state.production.settings(id)};
      final preset = <String, dynamic>{
        'name': '小说阅读',
        'values': {
          'font_size': 22.0,
          'text_alignment': 'justify',
          'visible_toc': true,
        },
      };
      state.layoutPresets = [preset];
      final preview = await state.production.previewChanges({
        for (final id in ids)
          id: {'op': 'apply_layout_preset', 'preset': preset},
      });
      for (final id in ids) {
        expect(state.production.settings(id), before[id]);
      }
      expect(await state.production.confirm(preview), true);
      for (final id in ids) {
        expect(state.production.settings(id)['font_size'], 22);
        expect(state.production.settings(id)['title'], before[id]!['title']);
        expect(
          state.production.settings(id)['css_font_permissions'],
          before[id]!['css_font_permissions'],
        );
      }
      state.layoutPresets = [
        {
          'name': '已修改的预设',
          'values': {'font_size': 16.0},
        },
      ];
      expect(state.production.settings(ids.first)['font_size'], 22);
      await expectLater(
        state.production.previewChanges({
          ids.first: {
            'op': 'apply_layout_preset',
            'preset': {
              'name': '非法',
              'values': {'title': '不能改书名'},
            },
          },
        }),
        throwsA(anything),
      );
      final project = '${dir.absolute.path}/presets.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(project);
      expect(reopened.layoutPresets, state.layoutPresets);
      expect(reopened.production.settings(ids.first)['font_size'], 22);
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            ids.first: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(
        reopened.production.settings(ids.first)['font_size'],
        before[ids.first]!['font_size'],
      );
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            ids.first: {'op': 'redo'},
          }),
        ),
        true,
      );
      expect(reopened.production.settings(ids.first)['font_size'], 22);
      final restoreBefore = reopened.production.settings(ids.first);
      final factory = await reopened.resolvedFactoryLayout();
      for (final invalidFields in [
        <String>[],
        ['font_size', 'font_size'],
        ['title'],
      ]) {
        await expectLater(
          reopened.production.previewChanges({
            ids.first: {
              'op': 'restore_layout',
              'defaults': factory,
              'fields': invalidFields,
            },
          }),
          throwsA(anything),
        );
      }
      final restorePreview = await reopened.production.previewChanges({
        ids.first: {
          'op': 'restore_layout',
          'defaults': factory,
          'fields': ['font_size'],
        },
      });
      expect(reopened.production.settings(ids.first), restoreBefore);
      expect(await reopened.production.confirm(restorePreview), true);
      final restoredValues = reopened.production.settings(ids.first);
      for (final e in restoreBefore.entries) {
        if (e.key == 'layout_origins') continue;
        expect(restoredValues[e.key], e.key == 'font_size' ? 18.0 : e.value);
      }
      final expectedOrigins = Map<String, dynamic>.from(
        restoreBefore['layout_origins'] as Map,
      )..['font_size'] = {'source': 'restored_default', 'value': 18.0};
      expect(restoredValues['layout_origins'], expectedOrigins);
      final restoredProject = '${dir.absolute.path}/restored.easypub.json';
      await reopened.saveProjectOutcome(restoredProject);
      await state.openProjectOutcome(restoredProject);
      expect(state.production.settings(ids.first)['font_size'], 18.0);
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            ids.first: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(state.production.settings(ids.first)['font_size'], 22.0);
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            ids.first: {'op': 'redo'},
          }),
        ),
        true,
      );
      expect(state.production.settings(ids.first)['font_size'], 18.0);
      await File('../artifacts/audit-20261004/baseline/evidence/r5-layout-presets.json').writeAsString(
        jsonEncode({
          'passed': true,
          'explicit_batch': true,
          'preview_nonmutating': true,
          'preset_edit_not_retroactive': true,
          'project_history': true,
          'global_defaults_implemented': false,
          'layer_priority_and_explicit_restore': true,
          'selected_restore_fields_project_history': true,
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
