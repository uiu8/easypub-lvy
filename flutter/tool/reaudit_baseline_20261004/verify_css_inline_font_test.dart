import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import '../legacy_state_helpers.dart';

void main() {
  test('inline CSS font license is content bound and survives project reopen', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r5-css-inline-font/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final font = await File(r'C:\Windows\Fonts\marlett.ttf')
        .copy('${dir.absolute.path}/sample.ttf');
    final original = await font.readAsBytes();
    final txt = await File('${dir.absolute.path}/book.txt')
        .writeAsString('Chapter 1\nText');
    final state = PrototypeState();
    final reopened = PrototypeState();
    try {
      await state.importBookOutcome(txt.path);
      final id = state.currentId;
      final css =
          '@font-face { font-family: sample; src: url("data:font/ttf;base64,${base64Encode(original)}"); }';
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
          ((await s.production.publicationResources(id))['manifest']['css_media'] as List)
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
      Future<void> replaceInline(List<int> bytes) async {
        final css =
            '@font-face { font-family: sample; src: url("data:font/ttf;base64,${base64Encode(bytes)}"); }';
        expect(
          await state.production.confirm(
            await state.production.previewChanges({
              id: {
                'op': 'patch',
                'fields': {
                  'additional_css': {'op': 'set', 'value': css},
                },
              },
            }),
          ),
          true,
        );
      }

      await replaceInline([...original, 0]);
      expect((await audit(state))['status'], 'font_permission_required');
      // Invalid inline fonts prevent a complete dependency snapshot.
      await replaceInline([0, 1, 0, 0, 1, 2]);
      final bad = await state.production.publicationResources(id);
      expect(bad['manifest']['css_dependencies']['rewritten'], false);
      expect(bad['manifest']['css_dependencies']['issues'], isNotEmpty);
      await replaceInline(original);
      final project = '${dir.absolute.path}/font.easypub.json';
      await state.saveProjectOutcome(project);
      expect(File(project).existsSync(), true, reason: state.projectStatus);
      await font.rename('${font.path}.offline');
      await reopened.openProjectOutcome(project);
      final offline = await audit(reopened);
      expect(offline['status'], 'font_permission_confirmed');
      expect(offline['font']['sha256'], permitted['font']['sha256']);
      await File('../artifacts/reaudit-20261004/baseline/evidence/r5-css-inline-font.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'actual_dll': true,
          'font_audit': offline,
          'content_change_requires_new_permission': true,
          'malformed_font_rejected': true,
          'offline_snapshot_rechecked': true,
          'license_confirmed_in_synthetic_test': true,
          'permission_history_and_project': true,
          'reader_checked': false,
          'restriction_flags_inline':
              'not verified here; existing media checker retained',
        }),
      );
    } finally {
      state.dispose();
      reopened.dispose();
    }
  });
}
