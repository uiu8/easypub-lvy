import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import '../legacy_state_helpers.dart';

void main() {
  test('layout fields persist, batch and generate exact CSS through actual DLL', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r5-layout-parameters/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final a = File('${dir.absolute.path}/A.txt');
    final b = File('${dir.absolute.path}/B.txt');
    await a.writeAsString('第一章 开始\n正文');
    await b.writeAsString('第一章 开始\n另一份正文');
    final state = PrototypeState();
    final reopened = PrototypeState();
    try {
      await state.importBookOutcome(a.path);
      final idA = state.currentId;
      await state.importBookOutcome(b.path);
      final idB = state.currentId;
      final dependency = File('${dir.absolute.path}/base.css');
      await dependency.writeAsString('p { color: red; }');
      await File('${dir.absolute.path}/cover.png').writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMQVDIGAACuAGcVHqFfAAAAAElFTkSuQmCC',
        ),
      );
      expect(state.production.settings(idA)['visible_toc'], false);
      expect(state.production.settings(idA)['chapter_navigation'], false);
      final values = <String, dynamic>{
        'text_alignment': 'justify',
        'visible_toc': true,
        'chapter_navigation': true,
        'additional_css_base': dir.absolute.path,
        'additional_css': '/* 中文样式 */\n@import "base.css";\np { letter-spacing: 0.1em; background: url(cover.png); }',
        'paragraph_indent': 1.5,
        'paragraph_spacing': 0.7,
        'margin_top': 1.0,
        'margin_right': 2.0,
        'margin_bottom': 3.0,
        'margin_left': 4.0,
      };
      Future<ProductionPreview> patch(Map<String, dynamic> fields) =>
          state.production.previewChanges({
            idA: {
              'op': 'patch',
              'fields': {
                for (final e in fields.entries)
                  e.key: {'op': 'set', 'value': e.value},
              },
            },
          });
      for (final key in values.keys.where(
        (k) =>
            k != 'visible_toc' &&
            k != 'chapter_navigation' &&
            k != 'text_alignment' &&
            k != 'additional_css' &&
            k != 'additional_css_base',
      )) {
        await expectLater(patch({key: -0.1}), throwsA(anything));
        await expectLater(patch({key: 6.1}), throwsA(anything));
      }
      await expectLater(
        patch({'margin_left': '0; color:red'}),
        throwsA(anything),
      );
      await expectLater(
        patch({'text_alignment': 'left; color:red'}),
        throwsA(anything),
      );
      expect(state.production.settings(idA)['text_alignment'], 'start');
      await expectLater(patch({'visible_toc': 'true'}), throwsA(anything));
      await expectLater(patch({'chapter_navigation': 1}), throwsA(anything));
      final stale = await patch(values);
      await dependency.writeAsString('p { color: blue; }');
      expect(await state.production.confirm(stale), false);
      expect(await state.production.confirm(await patch(values)), true);
      expect(state.production.settings(idB)['paragraph_indent'], 2.0);
      expect(state.production.settings(idB)['text_alignment'], 'start');
      final ready = await state.production.publicationResources(idA);
      final css = ready['manifest']['stylesheet']['css'] as String;
      expect(ready['manifest']['css_dependencies']['files'], hasLength(2));
      expect(
        (ready['manifest']['css_media'] as List).where(
          (r) => r['status'] == 'image_decoded',
        ),
        hasLength(1),
      );
      final navigation = ready['manifest']['navigation'] as Map;
      expect(navigation['visible_toc'], true);
      expect(navigation['entries'], hasLength(1));
      expect(navigation['entries'][0]['title'], '第一章 开始');
      expect(navigation['chapters'], hasLength(1));
      expect(
        navigation['chapters'][0]['entry_id'],
        navigation['entries'][0]['entry_id'],
      );
      expect(navigation['chapters'][0]['previous'], isNull);
      expect(navigation['chapters'][0]['next'], isNull);
      expect(navigation['chapters'][0]['contents'], 'visible_toc');
      expect(ready['manifest']['css_dependencies']['issues'], isEmpty);
      expect(ready['manifest']['css_dependencies']['rewritten'], true);
      expect(ready['manifest']['css_dependencies']['resources'], hasLength(3));
      expect(ready['manifest']['stylesheet_order'], [
        ready['manifest']['stylesheet']['id'],
        ready['manifest']['css_dependencies']['root_id'],
      ]);
      expect(ready['manifest']['stylesheet']['additional_css_references'], {
        'references': ['base.css', 'cover.png'],
        'incomplete': false,
      });
      final resolutions =
          ready['manifest']['stylesheet']['additional_css_resolutions'] as List;
      expect(resolutions.every((r) => r['kind'] == 'local'), true);
      expect(
        File(resolutions[1]['local_path'] as String).absolute.uri
            .normalizePath(),
        File('${dir.absolute.path}/cover.png').absolute.uri.normalizePath(),
      );
      await expectLater(
        patch({'additional_css_base': 'relative/path'}),
        throwsA(anything),
      );
      expect(css, contains('p { text-align: justify; }'));
      expect(css, isNot(contains('/* User additional CSS */')));
      await expectLater(
        patch({'additional_css': 'a' * 262145}),
        throwsA(anything),
      );
      await expectLater(
        patch({'additional_css': 'p { }\u0000'}),
        throwsA(anything),
      );
      for (final selector in [
        '.title-page',
        '.volume-heading',
        '.chapter-heading',
        '.section-heading',
        '.toc ol',
        '.chapter-navigation',
        '.scene-break',
      ]) {
        expect(css, contains(selector));
      }
      expect(css, contains('@page { margin: 18px 36px 54px 72px; }'));
      expect(css, contains('p { margin: 0 0 0.7em; text-indent: 1.5em; }'));
      for (final e in values.entries) {
        expect(ready['manifest'][e.key], e.value);
      }
      final copy = await state.production.previewResources(
        idA,
        [idB],
        copyMetadata: false,
        copyCover: false,
        copyTypography: true,
        copyIllustrations: false,
        overwrite: true,
      );
      expect(await state.production.confirm(copy), true);
      for (final e in values.entries) {
        expect(state.production.settings(idB)[e.key], e.value);
      }
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            idB: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(state.production.settings(idB)['paragraph_indent'], 2.0);
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            idB: {'op': 'redo'},
          }),
        ),
        true,
      );
      await state.production.confirm(
        await state.production.previewChanges({
          idB: {
            'op': 'patch',
            'fields': {
              'additional_css_base': {'op': 'clear'},
            },
          },
        }),
      );
      await state.production.confirm(
        await state.production.previewResources(
          idA,
          [idB],
          copyMetadata: false,
          copyCover: false,
          copyTypography: true,
          copyIllustrations: false,
          overwrite: false,
        ),
      );
      expect(state.production.settings(idB)['additional_css_base'], '');
      await state.production.confirm(
        await state.production.previewChanges({
          idB: {'op': 'undo'},
        }),
      );
      final project = '${dir.absolute.path}/project.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      final savedDoc = jsonDecode(await File(project).readAsString()) as Map;
      final relativeBundle =
          (savedDoc['books'] as List)
                  .first['additional_css_bundle']['directory']
              as String;
      expect(File(relativeBundle).isAbsolute, false);
      final bundleRoot = relativeBundle.replaceAll('\\', '/').split('/').first;
      final relocated = await Directory('${dir.absolute.path}/relocated')
          .create();
      await Directory('${dir.absolute.path}/$bundleRoot')
          .rename('${relocated.path}/$bundleRoot');
      final movedProject = '${relocated.path}/project.easypub.json';
      await File(project).rename(movedProject);
      await dependency.rename('${dependency.path}.offline');
      await File('${dir.absolute.path}/cover.png')
          .rename('${dir.absolute.path}/cover.png.offline');
      await reopened.openProjectOutcome(movedProject);
      expect(
        reopened.projectPath,
        movedProject,
        reason: reopened.projectStatus,
      );

      for (final id in [idA, idB]) {
        for (final e in values.entries) {
          expect(reopened.production.settings(id)[e.key], e.value);
        }
        expect(
          (await reopened.production.publicationResources(
            id,
          ))['manifest']['stylesheet']['css'],
          css,
        );
      }
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            idA: {
              'op': 'patch',
              'fields': {
                'additional_css': {'op': 'clear'},
              },
            },
          }),
        ),
        true,
      );
      expect(state.production.settings(idA)['additional_css'], '');
      expect(
        (await state.production.publicationResources(
          idA,
        ))['manifest']['stylesheet']['css'],
        isNot(contains('/* User additional CSS */')),
      );
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            idA: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(
        (await state.production.publicationResources(
          idA,
        ))['manifest']['stylesheet']['css'],
        css,
      );
      for (final id in [idA, idB]) {
        final offline = await reopened.production.publicationResources(id);
        expect(offline['manifest']['css_dependencies']['issues'], isEmpty);
        expect(
          offline['manifest']['css_dependencies']['root_id'],
          ready['manifest']['css_dependencies']['root_id'],
        );
      }
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            idA: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(reopened.production.settings(idA)['additional_css'], '');
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            idA: {'op': 'redo'},
          }),
        ),
        true,
      );
      expect(
        (await reopened.production.publicationResources(
          idA,
        ))['manifest']['css_dependencies']['root_id'],
        ready['manifest']['css_dependencies']['root_id'],
      );
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            idA: {
              'op': 'patch',
              'fields': {
                'additional_css': {'op': 'set', 'value': 'p { color: green; }'},
              },
            },
          }),
        ),
        true,
      );
      expect(reopened.production.settings(idA)['additional_css_bundle'], isNull);
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            idA: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(
        reopened.production.settings(idA)['additional_css_bundle'],
        isNotNull,
      );
      final copyProject = '${relocated.path}/offline-copy.easypub.json';
      await reopened.saveProjectOutcome(copyProject);
      expect(
        File(copyProject).existsSync(),
        true,
        reason: reopened.projectStatus,
      );
      final savedReference =
          reopened.production.settings(idA)['additional_css_bundle'] as Map;
      final damaged = File(
        '${savedReference['directory']}/resources/${ready['manifest']['css_dependencies']['root_id']}',
      );
      final originalBundleBytes = await damaged.readAsBytes();
      await damaged.writeAsString('corrupted snapshot');
      await reopened.openProjectOutcome(movedProject);
      expect(
        reopened.production.resourceIssues.values
            .expand((v) => v)
            .any((v) => v['kind'] == 'css_bundle'),
        true,
      );
      expect(
        (await reopened.production.publicationResources(
          idA,
        ))['manifest']['css_dependencies']['rewritten'],
        false,
      );
      await damaged.writeAsBytes(originalBundleBytes);
      Future<ProductionPreview> relocateBundle(String directory) =>
          reopened.production.previewChanges({
            idA: {
              'op': 'patch',
              'fields': {
                'additional_css_bundle': {
                  'op': 'set',
                  'value': {...savedReference, 'directory': directory},
                },
              },
            },
          });
      await expectLater(
        relocateBundle('${dir.absolute.path}/missing-bundle'),
        throwsA(anything),
      );
      final movedBundle = '${relocated.path}/repaired-css-bundle';
      await Directory(savedReference['directory'] as String)
          .rename(movedBundle);
      expect(
        await reopened.production.confirm(await relocateBundle(movedBundle)),
        true,
      );
      expect(
        (await reopened.production.publicationResources(
          idA,
        ))['manifest']['css_dependencies']['root_id'],
        ready['manifest']['css_dependencies']['root_id'],
      );
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            idA: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            idA: {'op': 'redo'},
          }),
        ),
        true,
      );
      expect(
        reopened.production.settings(idA)['additional_css_bundle']['directory'],
        movedBundle,
      );

      expect(await a.readAsString(), '第一章 开始\n正文');
      await File('../artifacts/reaudit-20261004/baseline/evidence/r5-layout-parameters.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'actual_dll': true,
          'values': values,
          'css': css,
          'batch_explicit_scope': true,
          'undo_redo': true,
          'project_roundtrip': true,
          'bounds_and_css_injection_rejected': true,
          'source_unchanged': true,
          'export_job_created': false,
          'css_dependencies': ready['manifest']['css_dependencies'],
          'css_media': ready['manifest']['css_media'],
          'dependency_changed_after_preview_rejected': true,
          'offline_project_relocated_and_resaved': true,
          'css_bundle_relocation_validated_and_reversible': true,
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
