import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test(
    'units survive edit, all four ebook exports and project reopen',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = (await Directory(
        '../artifacts',
      ).createTemp('units-roundtrip-')).absolute;
      final state = PrototypeState(settingsDirectory: '${root.path}/settings');
      final library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('${root.path}/units.txt')
        ..writeAsStringSync('第一章 开始\n第一段正文，测试单位与分页。\n第二段文字和标点。\n第二章 结束\n这是结束。');
      await library.importFiles([file.path]);
      final id = state.currentId;
      const patch = <String, Object>{
        'layout_units_version': 1,
        'font_size': 12.0,
        'font_size_unit': 'pt',
        'line_height': 120.0,
        'line_height_unit': '%',
        'paragraph_indent': 5.0,
        'paragraph_indent_unit': '%',
        'paragraph_spacing': 6.0,
        'paragraph_spacing_unit': 'pt',
        'margin_top': 5.0,
        'margin_top_unit': '%',
        'margin_left': 2.0,
        'margin_left_unit': 'em',
      };
      final layout = library.openLayout(id);
      await layout.apply(await layout.preview(patch));
      for (final e in patch.entries) {
        expect(state.production.settings(id)[e.key], e.value, reason: e.key);
      }
      final generated = await (layout as LayoutPublicationPreviewSession)
          .renderPreview();
      expect(File(generated.path).existsSync(), true);
      for (final format in ['EPUB', 'AZW3', 'MOBI', 'KFX']) {
        final c = LegacyConversionSession(state);
        final plan = await c.preview(
          ConversionRequest(
            books: [id],
            directory: root.path,
            format: format,
            engine:
                Platform.environment[format == 'KFX'
                    ? 'EASYPUB_TEST_BOKAI'
                    : 'EASYPUB_TEST_KINDLING']!,
            generateCover: true,
            runChecks: false,
          ),
        );
        expect(plan.previewed, true, reason: format);
        final result = (await c.commit(plan, acknowledgeWarnings: true)).single;
        expect(result.complete, true, reason: '$format: ${result.detail}');
        c.dispose();
      }
      final project = '${root.path}/saved.easypub.json';
      expect((await library.saveProject(project)).succeeded, true);
      final state2 = PrototypeState(settingsDirectory: '${root.path}/reopen');
      final library2 = LegacyLibraryAdapter(backend: state2);
      await library2.load();
      expect((await library2.openProject(project)).succeeded, true);
      for (final e in patch.entries) {
        expect(
          state2.production.settings(id)[e.key],
          e.value,
          reason: 'reopen ${e.key}',
        );
      }
      layout.dispose();
      library2.dispose();
      state2.dispose();
      library.dispose();
      state.dispose();
    },
  );
}
