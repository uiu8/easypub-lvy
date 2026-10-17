import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cover crop actual resources history and project', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(Platform.environment['EASYPUB_TEST_DLL'] ?? '../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r5-cover-crop/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 8, 6),
      ui.Paint()..color = const ui.Color(0xffab1234),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(8, 6);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
    final cover = File('${dir.absolute.path}/cover.png');
    await cover.writeAsBytes(bytes);
    final txt = File('${dir.absolute.path}/book.txt');
    await txt.writeAsString('第一章 甲\n正文');
    final state = PrototypeState(), reopened = PrototypeState();
    const crop = {'x': 0.25, 'y': 0.5, 'width': 0.5, 'height': 0.5};
    try {
      await state.importBookOutcome(txt.path);
      final id = state.currentId;
      final preview = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'cover_path': {'op': 'set', 'value': cover.path},
            'cover_crop': {'op': 'set', 'value': crop},
            'illustrations': {
              'op': 'set',
              'value': [
                {
                  'path': cover.path,
                  'caption': '',
                  'alt': '',
                  'source_line': 2,
                },
              ],
            },
          },
        },
      });
      expect(state.production.settings(id)['cover_crop'], isNull);
      expect(await state.production.confirm(preview), true);
      final manifest =
          (await state.production.publicationResources(id))['manifest'] as Map;
      final resources = (manifest['resources'] as List).cast<Map>();
      final cropped = resources.singleWhere(
        (r) => r['id'] == manifest['cover'],
      );
      expect([cropped['width'], cropped['height']], [4, 3]);
      final original = resources.singleWhere(
        (r) => r['id'] != manifest['cover'],
      );
      expect([original['width'], original['height']], [8, 6]);
      final project = '${dir.absolute.path}/project.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      await reopened.openProjectOutcome(project);
      expect(reopened.production.settings(id)['cover_crop'], crop);
      expect((await reopened.production.publicationResources(id))['manifest'], manifest);
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            id: {
              'op': 'patch',
              'fields': {
                'cover_crop': {'op': 'clear'},
              },
            },
          }),
        ),
        true,
      );
      expect(reopened.production.settings(id)['cover_crop'], isNull);
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            id: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(reopened.production.settings(id)['cover_crop'], crop);
      await expectLater(
        reopened.production.previewChanges({
          id: {
            'op': 'patch',
            'fields': {
              'cover_crop': {
                'op': 'set',
                'value': {...crop, 'width': 2},
              },
            },
          },
        }),
        throwsA(anything),
      );
      final second = File('${dir.absolute.path}/second.txt');
      await second.writeAsString('第一章 乙\n正文乙');
      await reopened.importBookOutcome(second.path);
      final secondId = reopened.currentId;
      Future<ProductionPreview> copyCover() =>
          reopened.production.previewResources(
            id,
            [secondId],
            copyMetadata: false,
            copyCover: true,
            copyTypography: false,
            copyIllustrations: false,
            overwrite: false,
          );
      expect(await reopened.production.confirm(await copyCover()), true);
      expect(reopened.production.settings(secondId)['cover_crop'], crop);
      expect(
        await reopened.production.confirm(
          await reopened.production.previewChanges({
            secondId: {
              'op': 'patch',
              'fields': {
                'cover_crop': {'op': 'clear'},
              },
            },
          }),
        ),
        true,
      );
      expect(await reopened.production.confirm(await copyCover()), true);
      expect(
        reopened.production.settings(secondId)['cover_crop'],
        isNull,
        reason: 'fill-only copy must retain existing cover geometry',
      );
      final pending = await reopened.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'cover_crop': {'op': 'clear'},
          },
        },
      });
      await cover.writeAsString('changed');
      expect(await reopened.production.confirm(pending), false);
      expect(reopened.production.settings(id)['cover_crop'], crop);
      await cover.writeAsBytes(bytes);
      expect(await txt.readAsString(), '第一章 甲\n正文');
      await File('../docs/evidence/r5-cover-crop.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'verified_at': DateTime.now().toIso8601String(),
          'checks': [
            '8x6 original and 4x3 derivative separate',
            'preview does not apply',
            'project and resource manifest roundtrip',
            'clear and undo',
            'batch copies crop to empty cover and preserves existing cover geometry',
            'out-of-bounds rejected',
            'changed original blocks confirmation',
            'TXT unchanged',
          ],
          'not_verified': [
            'crop editor UI',
            'Flutter cover rendering',
            'EPUB export',
          ],
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
