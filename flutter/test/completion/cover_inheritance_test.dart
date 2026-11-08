import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';

import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('cover inheritance restores image recipe and crop together; replacing an image clears its crop', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('cover-inheritance-')).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('${root.path}/sample.txt')
        ..writeAsStringSync('第一章 开始\n合成正文。\n');
      await library.importFiles([file.path]);
      final id = state.currentId;
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgZGIGAAAOAAfXb+R4AAAAAElFTkSuQmCC',
      );
      final cover = File('${root.path}/cover.png')..writeAsBytesSync(bytes);
      final other = File('${root.path}/other.png')..writeAsBytesSync(bytes);
      final design = {
        'title': '合成封面',
        'author': '作者',
        'series': '',
        'color': 0xff23664f,
        'style': 'river-classic-v1',
        'image_sha256': sha256.convert(bytes).toString(),
      };
      final crop = {'x': 0.0, 'y': 0.0, 'width': 0.5, 'height': 1.0};
      final info = library.openBookInformation(id);
      await info.apply(
        await info.preview({
          'cover_path': cover.path,
          'cover_design': design,
          'cover_crop': crop,
        }),
      );
      info.dispose();
      final before = state.production.settings(id);
      expect(
        library.books.value.singleWhere((b) => b.id == id).coverDesign,
        design,
      );
      expect(
        library.books.value.singleWhere((b) => b.id == id).coverCrop,
        crop,
      );
      var mapping = library.openMapping();
      final restore = await (mapping as MappingOverrideSession)
          .previewOverrides(
            [],
            [id],
            {},
            restoreFields: {
              id: {'cover_path'},
            },
          );
      expect(restore.items.single.after['cover_path'], isNull);
      expect(restore.items.single.after['cover_design'], isNull);
      expect(restore.items.single.after['cover_crop'], isNull);
      expect(
        restore.items.single.changed,
        containsAll(['cover_path', 'cover_design', 'cover_crop']),
      );
      expect(state.production.settings(id), before);
      await mapping.apply(restore);
      final project = '${root.path}/restored.easypub.json';
      expect((await library.saveProject(project)).succeeded, true);
      final reopened = PrototypeState(
        settingsDirectory: '${root.path}/settings',
      );
      final library2 = LegacyLibraryAdapter(backend: reopened);
      try {
        await library2.load();
        expect((await library2.openProject(project)).succeeded, true);
        expect(reopened.production.settings(id)['cover_path'], isNull);
        expect(reopened.production.settings(id)['cover_design'], isNull);
        expect(reopened.production.settings(id)['cover_crop'], isNull);
        final converter = LegacyConversionSession(reopened);
        try {
          final plan = await converter.preview(
            ConversionRequest(
              books: [id],
              directory: '${root.path}/output',
              format: 'EPUB',
              generateCover: false,
              runChecks: false,
            ),
          );
          expect(plan.previewed, true);
          final output = (await converter.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(output.complete, true, reason: output.detail);
        } finally {
          converter.dispose();
        }
      } finally {
        library2.dispose();
        reopened.dispose();
      }

      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(state.production.settings(id), before);
      final replacement = library.openBookInformation(id);
      final replace = await replacement.preview({'cover_path': other.path});
      await replacement.apply(replace);
      replacement.dispose();
      expect(state.production.settings(id)['cover_design'], isNull);
      expect(state.production.settings(id)['cover_crop'], isNull);
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(state.production.settings(id), before);
      mapping = library.openMapping();
      final overridden = await (mapping as MappingOverrideSession)
          .previewOverrides(
            [
              MappingRule(root.path, {
                'cover_path': {'op': 'set', 'value': other.path},
              }),
            ],
            [id],
            {
              id: {'cover_path'},
            },
          );
      expect(overridden.items.single.after['cover_crop'], isNull);
      expect(overridden.items.single.after['cover_design'], isNull);
      await mapping.apply(overridden);
      final removed = await mapping.preview([], [id]);
      expect(removed.items.single.after['cover_path'], isNull);
      expect(removed.items.single.after['cover_design'], isNull);
      expect(removed.items.single.after['cover_crop'], isNull);
      expect(file.readAsStringSync(), '第一章 开始\n合成正文。\n');
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
