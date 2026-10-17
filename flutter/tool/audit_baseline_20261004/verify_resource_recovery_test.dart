import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resource recovery preserves project and source and validates replacements atomically', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(Platform.environment['EASYPUB_TEST_DLL'] ?? '../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r5-resource-recovery/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final temp = await Directory.systemTemp.createTemp('easypub-recovery-');
    final oldFont = await File(r'C:\Windows\Fonts\arial.ttf')
        .copy('${temp.path}/old.ttf');
    final newFont = File('${temp.path}/new.ttf');
    final source = File('${dir.absolute.path}/Book.txt');
    await source.writeAsString('ABC\nDEF');
    final oldImage = File('${dir.absolute.path}/old.png');
    final newImage = File('${dir.absolute.path}/new.png');
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgZGIGAAAOAAfXb+R4AAAAAElFTkSuQmCC',
    );
    await oldImage.writeAsBytes(png);
    final state = PrototypeState();
    final reopened = PrototypeState();
    try {
      await state.importBookOutcome(source.path);
      final id = state.currentId;
      state.title = 'Book';
      state.author = 'Author';
      final inspected = jsonDecode(
        await api.inspectFontText(
          path: oldFont.path,
          faceIndex: 0,
          sample: 'ABC',
        ),
      ) as Map;
      final font = {
        'path': oldFont.path,
        'face_index': 0,
        'sha256': inspected['sha256'],
        'license_confirmed': true,
      };
      final illustration = {
        'path': oldImage.path,
        'source_line': 2,
        'caption': 'Figure',
        'alt': 'Image',
      };
      Future<ProductionPreview> patch(
        PrototypeState s,
        Map<String, dynamic> values,
      ) => s.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            for (final e in values.entries)
              e.key: {'op': 'set', 'value': e.value},
          },
        },
      });
      expect(
        await state.production.confirm(
          await patch(state, {
            'cover_path': oldImage.path,
            'illustrations': [illustration],
            'font_resource': font,
          }),
        ),
        true,
      );
      final project = File('${dir.absolute.path}/original.easypub.json');
      await state.saveProjectOutcome(project.path);
      expect(await project.exists(), true, reason: state.projectStatus);
      final originalProject = await project.readAsBytes();
      await oldImage.rename(newImage.path);
      await oldFont.rename(newFont.path);
      await reopened.openProjectOutcome(project.path);
      expect(reopened.currentId, id, reason: reopened.projectStatus);
      expect(reopened.production.resourceIssues[id]!.map((e) => e['kind']).toSet(), {
        'cover',
        'illustration',
        'font',
      });
      expect(reopened.production.settings(id)['illustrations'], [illustration]);
      await expectLater(reopened.production.publicationResources(id), throwsA(anything));
      final unresolved = File('${dir.absolute.path}/unresolved.easypub.json');
      await reopened.saveProjectOutcome(unresolved.path);
      expect(await unresolved.exists(), true, reason: reopened.projectStatus);
      await expectLater(
        patch(reopened, {'cover_path': newImage.path}),
        throwsA(anything),
      );
      expect(reopened.production.settings(id)['cover_path'], oldImage.path);
      final replacements = {
        'cover_path': newImage.path,
        'illustrations': [
          {...illustration, 'path': newImage.path},
        ],
        'font_resource': {...font, 'path': newFont.path},
      };
      final preview = await patch(reopened, replacements);
      await newImage.writeAsBytes([...png, 0]);
      expect(await reopened.production.confirm(preview), false);
      expect(reopened.production.settings(id)['cover_path'], oldImage.path);
      await newImage.writeAsBytes(png);
      expect(
        await reopened.production.confirm(await patch(reopened, replacements)),
        true,
      );
      expect(reopened.production.resourceIssues[id], isNull);
      final manifest =
          (await reopened.production.publicationResources(id))['manifest'] as Map;
      expect(manifest['placements'][0]['original_line'], 2);
      expect(manifest['placements'][0]['caption'], 'Figure');
      expect(manifest['font']['output']['missing_count'], 0);
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            id: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(reopened.production.resourceIssues[id]!.length, 3);
      expect(reopened.production.settings(id)['cover_path'], oldImage.path);
      await expectLater(reopened.production.publicationResources(id), throwsA(anything));
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            id: {'op': 'redo'},
          }),
        ),
        true,
      );
      expect(reopened.production.resourceIssues[id], isNull);
      final recovered = File('${dir.absolute.path}/recovered.easypub.json');
      await reopened.saveProjectOutcome(recovered.path);
      await state.openProjectOutcome(recovered.path);
      expect(state.production.resourceIssues, isEmpty);
      expect((await state.production.publicationResources(id))['manifest'], manifest);
      expect(await project.readAsBytes(), originalProject);
      expect(await source.readAsString(), 'ABC\nDEF');
      await source.writeAsString('Changed');
      await state.openProjectOutcome(recovered.path);
      expect(state.projectStatus, contains('原稿已在外部修改'));
      expect(state.currentId, id);
      await source.writeAsString('ABC\nDEF');
      await File('../artifacts/audit-20261004/baseline/evidence/r5-resource-recovery.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'actual_dll': true,
          'missing_resource_project_opens': true,
          'three_issues_reported': true,
          'unresolved_references_saved': true,
          'partial_repair_rejected_without_mutation': true,
          'changed_image_before_commit_rejected': true,
          'captions_and_positions_preserved': true,
          'undo_restores_missing_references_without_export': true,
          'redo_restores_resources': true,
          'project_roundtrip': true,
          'original_project_and_source_unchanged': true,
          'changed_source_still_rejected': true,
          'export_job_created': false,
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
      if (await oldFont.exists()) await oldFont.delete();
      if (await newFont.exists()) await newFont.delete();
      await temp.delete();
    }
  });
}
