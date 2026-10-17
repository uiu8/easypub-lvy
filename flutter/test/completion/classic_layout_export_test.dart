import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('classic XML defaults survive export and project reopen without changing source', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('classic-layout-'))
        .absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final outputs = <Map<String, Object?>>[];
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final config = Platform.environment['EASYPUB_LAYOUT_CONFIG'];
      final factory = await state.resolvedFactoryLayout();
      expect(factory['font_size'], 110);
      expect(factory['font_size_unit'], '%');
      expect(factory['line_height'], 1.2);
      expect(factory['fullwidth_indent'], 2);
      expect(factory['remove_blank_lines'], true);
      expect(factory['paragraph_indent'], 0);
      if (config != null) {
        final report = (await library.inspectLegacy(config))['report'] as Map;
        final values = Map<String, dynamic>.from(
          report['proposed_layout'] as Map,
        );
        for (final entry in values.entries) {
          expect(factory[entry.key], entry.value, reason: entry.key);
        }
        expect(await library.savePatch({'layout_defaults': values}), true);
      }
      final supplied = Platform.environment['EASYPUB_LAYOUT_SOURCE'];
      final source = supplied == null
          ? (File('${root.path}/经典排版.txt')..writeAsStringSync(
              '第一章 开始\n　　已有两个全角空格。\n\n没有缩进的正文。\n第二章 结束\n尾段正文。\n',
            ))
          : File(supplied);
      final before = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = state.currentId;
      final layout = library.openLayout(id);
      final generated = await (layout as LayoutPublicationPreviewSession)
          .renderPreview();
      expect(File(generated.path).existsSync(), true);
      expect(generated.path, endsWith('.html'));
      expect(generated.documents, isNotEmpty);
      expect(File(generated.path).readAsStringSync(), contains('iframe'));
      layout.dispose();
      expect(state.production.settings(id)['font_size_unit'], '%');
      for (final format in ['EPUB', 'AZW3', 'MOBI', 'KFX']) {
        final session = LegacyConversionSession(state);
        try {
          final plan = await session.preview(
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
          expect(
            plan.previewed,
            true,
            reason: plan.findings.map((e) => e.detail).join('\n'),
          );
          final result = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(result.complete, true, reason: result.detail);
          outputs.add({'format': format, 'path': result.path});
        } finally {
          session.dispose();
        }
      }
      final project = '${root.path}/saved.easypub.json';
      expect((await library.saveProject(project)).succeeded, true);
      final restored = PrototypeState(
        settingsDirectory: '${root.path}/settings',
      );
      final reopened = LegacyLibraryAdapter(backend: restored);
      try {
        await reopened.load();
        expect((await reopened.openProject(project)).succeeded, true);
        final settings = restored.production.settings(restored.currentId);
        expect(settings['font_size_unit'], '%');
        expect(settings['font_size'], 110);
        expect(settings['fullwidth_indent'], 2);
        expect(settings['remove_blank_lines'], true);
      } finally {
        reopened.dispose();
        restored.dispose();
      }
      expect(source.readAsBytesSync(), before);
    } finally {
      File('${root.path}/evidence.json').writeAsStringSync(jsonEncode(outputs));
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
