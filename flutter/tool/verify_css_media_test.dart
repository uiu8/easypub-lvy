import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_helpers.dart';

void main() {
  test(
    'CSS font bytes, restrictions and offline media audit use actual DLL',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File(
            Platform.environment['EASYPUB_TEST_DLL'] ??
                '../target/release/easypub_bridge.dll',
          ).absolute.path,
        ),
      );
      final dir = await Directory(
        '../artifacts/r5-css-media/${DateTime.now().microsecondsSinceEpoch}',
      ).create(recursive: true);
      final font = await File(r'C:\Windows\Fonts\arial.ttf')
          .copy('${dir.absolute.path}/sample.ttf');
      final original = await font.readAsBytes();
      final txt = await File('${dir.absolute.path}/book.txt')
          .writeAsString('Chapter 1\nText');
      final state = PrototypeState();
      final reopened = PrototypeState();
      try {
        await state.importBookOutcome(txt.path);
        final id = state.currentId;
        final css = '@font-face { font-family: sample; src: url(sample.ttf); }';
        expect(
          await state.production.confirm(
            await state.production.previewChanges({
              id: {
                'op': 'patch',
                'fields': {
                  'additional_css': {'op': 'set', 'value': css},
                  'additional_css_base': {
                    'op': 'set',
                    'value': dir.absolute.path,
                  },
                },
              },
            }),
          ),
          true,
        );
        Future<Map> audit(PrototypeState s) async =>
            ((await s.production.publicationResources(id))['manifest']['css_media']
                    as List)
                .cast<Map>()
                .firstWhere((r) => (r['id'] as String).endsWith('.ttf'));
        final permitted = await audit(state);
        expect(permitted['status'], 'font_permission_required');
        expect(permitted['font']['license_confirmation_required'], true);
        Future<ProductionPreview> permissions(List<String> values) =>
            state.production.previewChanges({
              id: {
                'op': 'patch',
                'fields': {
                  'css_font_permissions': {'op': 'set', 'value': values},
                },
              },
            });
        await expectLater(permissions(['invalid']), throwsA(anything));
        final fontHash = permitted['font']['sha256'] as String;
        await expectLater(permissions([fontHash, fontHash]), throwsA(anything));
        expect(
          await state.production.confirm(await permissions([fontHash])),
          true,
        );
        expect((await audit(state))['status'], 'font_permission_confirmed');
        expect(
          await state.production.confirm(
            await state.production.previewChanges({
              id: {'op': 'undo'},
            }),
          ),
          true,
        );
        expect((await audit(state))['status'], 'font_permission_required');
        expect(
          await state.production.confirm(
            await state.production.previewChanges({
              id: {'op': 'redo'},
            }),
          ),
          true,
        );
        final second = await File('${dir.absolute.path}/second.txt')
            .writeAsString('Second book');
        await state.importBookOutcome(second.path);
        final otherId = state.currentId;
        expect(
          await state.production.confirm(
            await state.production.previewResources(
              id,
              [otherId],
              copyMetadata: false,
              copyCover: false,
              copyTypography: true,
              copyIllustrations: false,
              overwrite: true,
            ),
          ),
          true,
        );
        expect(
          state.production.settings(otherId)['css_font_permissions'],
          isEmpty,
        );
        await font.writeAsBytes([...original, 0]);
        expect((await audit(state))['status'], 'font_permission_required');
        final restricted = Uint8List.fromList(original);
        final data = ByteData.sublistView(restricted);
        var changed = false;
        for (var i = 0; i < data.getUint16(4); i++) {
          final table = 12 + i * 16;
          if (ascii.decode(restricted.sublist(table, table + 4)) == 'OS/2') {
            final offset = data.getUint32(table + 8);
            data.setUint16(offset + 8, 2);
            changed = true;
            break;
          }
        }
        expect(changed, true);
        await font.writeAsBytes(restricted);
        expect((await audit(state))['status'], 'font_embedding_restricted');
        final restrictedHash = (await audit(state))['font']['sha256'] as String;
        expect(
          await state.production.confirm(await permissions([restrictedHash])),
          true,
        );
        expect((await audit(state))['status'], 'font_embedding_restricted');
        expect(
          await state.production.confirm(await permissions([fontHash])),
          true,
        );
        await font.writeAsBytes([0, 1, 0, 0, 1, 2]);
        expect((await audit(state))['status'], 'invalid_font');
        await font.writeAsBytes(original);
        final project = '${dir.absolute.path}/font.easypub.json';
        await state.saveProjectOutcome(project);
        expect(File(project).existsSync(), true, reason: state.projectStatus);
        await font.rename('${font.path}.offline');
        await reopened.openProjectOutcome(project);
        final offline = await audit(reopened);
        expect(offline['status'], 'font_permission_confirmed');
        expect(offline['font']['sha256'], permitted['font']['sha256']);
        await File('../docs/evidence/r5-css-media.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'actual_dll': true,
            'font_audit': offline,
            'restricted_flag_rejected': true,
            'malformed_font_rejected': true,
            'offline_snapshot_rechecked': true,
            'license_confirmed_in_synthetic_test': true,
            'permission_history_and_project': true,
            'reader_checked': false,
          }),
        );
      } finally {
        state.dispose();
        reopened.dispose();
      }
    },
  );
}
