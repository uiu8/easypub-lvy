import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('OUT-085：真实 AZW3/MOBI 转换的导航和起始位置指向第一章，保留序言', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('v47-navigation-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final source = File('$root/雾港.txt')
        ..writeAsStringSync('序\n引子正文。\n第一章 雾起\n正文甲。\n第二章 旧码头\n正文乙。\n');
      final original = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final layout = await state.production.previewChanges({
        state.currentId: {
          'op': 'patch',
          'fields': {
            'visible_toc': {'op': 'set', 'value': true},
          },
        },
      });
      expect(await state.production.confirm(layout), true);
      final evidence = <Object?>[];
      for (final format in ['AZW3', 'MOBI']) {
        final session = LegacyConversionSession(state);
        try {
          final plan = await session.preview(
            ConversionRequest(
              books: [state.currentId],
              directory: '$root/$format',
              format: format,
              engine: Platform.environment['EASYPUB_TEST_KINDLING']!,
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(plan.previewed, true);
          final output = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(output.complete, true, reason: output.detail);
          final inspection = await Process.run(
            Platform.environment['EASYPUB_TEST_PYTHON']!,
            [
              '-I',
              '-X',
              'utf8',
              '../tools/verify_kindle_navigation.py',
              output.path,
              '--expect-start',
              '第一章 雾起',
              '--require-text',
              '引子正文。',
            ],
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(
            inspection.exitCode,
            0,
            reason: '${inspection.stdout}\n${inspection.stderr}',
          );
          final report =
              jsonDecode(inspection.stdout as String) as Map<String, dynamic>;
          final sections = report['sections'] as List;
          expect(sections.length, format == 'MOBI' ? 2 : 1);
          for (final section in sections.cast<Map<String, dynamic>>()) {
            // Kindle 封面只由元数据提供：不登记封面导航，HTML 封面页不进正文流。
            expect((section['guide'] as Map).keys.toSet(), {'toc', 'text'});
            expect(section['start_text'], startsWith('第一章 雾起'));
          }
          evidence.add(report);
        } finally {
          session.dispose();
        }
      }
      expect(source.readAsBytesSync(), original);
      await File('$root/verification.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
