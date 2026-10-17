import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('font resources and persistent history through actual DLL', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r5-font-resources/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final temporary = await Directory.systemTemp.createTemp('easypub-font-');
    final font = await File(r'C:\Windows\Fonts\arial.ttf')
        .copy('${temporary.path}/font.ttf');
    final file = File('${dir.absolute.path}/Book.txt');
    const body = 'ABC\nDEF\n';
    await file.writeAsString(body);
    final state = PrototypeState();
    final reopened = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final id = state.currentId;
      state.title = 'Book';
      state.author = 'Author';
      state.draft.description = 'é';
      final report = jsonDecode(
        await api.inspectFontText(path: font.path, faceIndex: 0, sample: 'ABC'),
      ) as Map;
      final selection = <String, dynamic>{
        'path': font.path,
        'face_index': 0,
        'sha256': report['sha256'],
        'license_confirmed': true,
      };
      Future<ProductionPreview> select(Map<String, dynamic> value) =>
          state.production.previewChanges({
            id: {
              'op': 'patch',
              'fields': {
                'font_resource': {'op': 'set', 'value': value},
              },
            },
          });
      await expectLater(
        select({...selection, 'license_confirmed': false}),
        throwsA(anything),
      );
      await expectLater(
        select({...selection, 'sha256': '0' * 64}),
        throwsA(anything),
      );
      final preview = await select(selection);
      expect(
        preview.result['items'][0]['changed_fields'],
        contains('font_resource'),
      );
      expect(
        await state.production.confirm(preview),
        true,
        reason: state.production.batchStatus,
      );
      final ready = await state.production.publicationResources(id);
      final manifest = ready['manifest'] as Map;
      final prepared = manifest['font'] as Map;
      expect(prepared['output']['missing_count'], 0);
      expect(
        prepared['output']['requested_characters'],
        '${body}BookAuthoré'.runes.where((c) => c >= 32).toSet().length,
      );
      expect(prepared['output']['bytes'], lessThan(report['bytes'] as int));
      expect(manifest['stylesheet']['font_embedded'], true);
      expect(
        manifest['stylesheet']['css'],
        contains('url("${prepared['id']}")'),
      );
      expect(ready['export_job_created'], false);
      final path = '${dir.absolute.path}/project.easypub.json';
      await state.saveProjectOutcome(path);
      expect(File(path).existsSync(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(path);
      expect(
        reopened.production.settings(reopened.currentId)['font_resource'],
        selection,
      );
      expect(
        (await reopened.production.publicationResources(reopened.currentId))['manifest'],
        manifest,
      );
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            reopened.currentId: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(
        reopened.production.settings(reopened.currentId)['font_resource'],
        isNull,
      );
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            reopened.currentId: {'op': 'redo'},
          }),
        ),
        true,
      );
      expect(
        reopened.production.settings(reopened.currentId)['font_resource'],
        selection,
      );
      expect(
        await state.production.confirm(
          await select({...selection, 'mode': 'full'}),
        ),
        true,
      );
      final full =
          (await state.production.publicationResources(id))['manifest']['font'] as Map;
      expect(full['mode'], 'full');
      expect(full['output']['sha256'], report['sha256']);
      expect(full['output']['bytes'], report['bytes']);
      expect(full['output']['glyph_count'], report['glyph_count']);
      final fullProject = '${dir.absolute.path}/full.easypub.json';
      await state.saveProjectOutcome(fullProject);
      expect(File(fullProject).existsSync(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(fullProject);
      expect(
        reopened.production.settings(
          reopened.currentId,
        )['font_resource']['mode'],
        'full',
      );
      expect(
        (await reopened.production.publicationResources(
          reopened.currentId,
        ))['manifest']['font'],
        full,
      );
      final collectionReport = jsonDecode(
        await api.inspectFontText(
          path: r'C:\Windows\Fonts\simsun.ttc',
          faceIndex: 1,
          sample: 'ABC',
        ),
      ) as Map;
      final collectionRequest = {
        'source_id': state.current.source!.sourceId,
        'revision': state.current.source!.revision,
        'settings': {
          ...state.production.settings(id),
          'description': '',
          'font_resource': {
            'path': r'C:\Windows\Fonts\simsun.ttc',
            'face_index': 1,
            'mode': 'full',
            'sha256': collectionReport['sha256'],
            'license_confirmed': true,
          },
        },
      };
      final collection =
          jsonDecode(
                await api.publicationResourcesText(
                  requestJson: jsonEncode(collectionRequest),
                ),
              )['manifest']['font']
              as Map;
      expect(collection['mode'], 'full');
      expect(collection['output']['face_index'], 0);
      expect(
        collection['output']['glyph_count'],
        collectionReport['glyph_count'],
      );
      expect(collection['output']['missing_count'], 0);
      state.draft.description = 'é\u{10FFFF}';
      await expectLater(state.production.publicationResources(id), throwsA(anything));
      state.draft.description = 'é';
      final change = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'title': {'op': 'set', 'value': 'Changed'},
          },
        },
      });
      final bytes = await font.readAsBytes();
      await font.writeAsBytes([...bytes, 0]);
      expect(await state.production.confirm(change), false);
      await expectLater(state.production.publicationResources(id), throwsA(anything));
      await font.delete();
      final clear = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'font_resource': {'op': 'clear'},
          },
        },
      });
      expect(await state.production.confirm(clear), true);
      expect(
        (await state.production.publicationResources(id))['manifest']['font'],
        isNull,
      );
      expect(await file.readAsString(), body);
      await File('../docs/evidence/r5-font-resources.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'actual_dll': true,
          'full_single_font_bytes_unchanged': true,
          'full_mode_project_roundtrip': true,
          'full_collection_face_glyphs_preserved': true,
          'full_font': full,
          'full_collection_font': collection,
          'font': prepared,
          'css_binds_actual_subset': true,
          'final_text_and_metadata_coverage': true,
          'project_roundtrip': true,
          'undo_redo': true,
          'unconfirmed_and_wrong_hash_rejected': true,
          'missing_metadata_character_rejected': true,
          'changed_font_rejected_on_commit_and_prepare': true,
          'missing_font_can_be_cleared': true,
          'source_unchanged': true,
          'export_job_created': false,
          'temporary_font_removed': true,
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
      if (await font.exists()) await font.delete();
      await temporary.delete();
    }
  });
}
