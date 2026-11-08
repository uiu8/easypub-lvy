import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
  });
  for (final format in ['MOBI', 'AZW3']) {
    test(
      '$format retries the persisted original task after a real destination conflict',
      () async {
        final root = (await Directory(
          '../artifacts',
        ).createTemp('completion-kindle-retry-')).absolute;
        final settings = '${root.path}/settings';
        final state = PrototypeState(settingsDirectory: settings);
        final library = LegacyLibraryAdapter(backend: state);
        final session = LegacyConversionSession(state);
        try {
          await library.load();
          await library.savePatch({'check_after_import': false});
          final source = File('${root.path}/重试样书.txt')
            ..writeAsStringSync('第一章 清晨\n合成测试正文。\n第二章 傍晚\n第二段合成正文。\n');
          final original = source.readAsBytesSync();
          expect(
            (await library.importFiles([source.path])).single.succeeded,
            true,
          );
          final plan = await session.preview(
            ConversionRequest(
              books: [state.currentId],
              directory: '${root.path}/original',
              format: format,
              engine: Platform.environment['EASYPUB_TEST_KINDLING']!,
              language: 'en',
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(
            plan.previewed,
            true,
            reason: plan.findings.map((f) => f.detail).join('\n'),
          );
          final target = File(plan.outputs.single.path);
          target.writeAsStringSync('synthetic occupied file - must survive');
          final failed = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(failed.failed, true);
          expect(
            target.readAsStringSync(),
            'synthetic occupied file - must survive',
          );
          final task = state.outputs.tasks.single;
          expect(task.phase, 'failed');
          final project = '${root.path}/project.easypub.json';
          expect((await library.saveProject(project)).succeeded, true);
          await library.savePatch({
            'output_directory': '${root.path}/different',
            'output_format': 'EPUB',
            'default_language': 'ja',
            'kindle_converter': 'D:/not-original.exe',
          });
          // This file was created by this test at its freshly allocated output path.
          target.deleteSync();
          final reopened = PrototypeState(settingsDirectory: settings);
          final reopenedLibrary = LegacyLibraryAdapter(backend: reopened),
              retry = LegacyConversionSession(reopened);
          try {
            await reopenedLibrary.load();
            expect(
              (await reopenedLibrary.openProject(project)).succeeded,
              true,
            );
            final restored = await retry.previewRetry([task.taskId]);
            expect(
              restored.previewed,
              true,
              reason: restored.findings.map((f) => f.detail).join('\n'),
            );
            expect(retry.request!.format, format);
            expect(retry.request!.language, 'en');
            expect(
              retry.request!.engine,
              Platform.environment['EASYPUB_TEST_KINDLING'],
            );
            expect(retry.request!.directory, '${root.path}/original');
            expect(restored.outputs.single.path, target.path);
            final result = (await retry.commit(
              restored,
              acknowledgeWarnings: true,
            )).single;
            expect(result.complete, true, reason: result.detail);
            final bytes = target.readAsBytesSync();
            expect(bytes.length, greaterThan(1000));
            expect(String.fromCharCodes(bytes.sublist(60, 68)), 'BOOKMOBI');
            expect(source.readAsBytesSync(), original);
            expect(target.parent.listSync().whereType<Directory>(), isEmpty);
            expect(
              reopened.outputs.tasks.where((t) => t.phase == 'complete').length,
              1,
            );
            expect(
              reopened.outputs.batchRecords.last['retry_of_batch_id'],
              task.batchId,
            );
          } finally {
            retry.dispose();
            reopenedLibrary.dispose();
            reopened.dispose();
          }
        } finally {
          session.dispose();
          library.dispose();
          state.dispose();
        }
      },
    );
  }
}
