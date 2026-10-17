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
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  for (final format in [
    'MOBI',
    'AZW3',
    if (Platform.environment.containsKey('EASYPUB_TEST_BOKAI')) 'KFX',
  ]) {
    test(
      '$format native cancellation agrees across batch, retry and restored history',
      () async {
        final root = (await Directory(
          '../artifacts',
        ).createTemp('completion-cancel-')).absolute;
        final state = PrototypeState(
          settingsDirectory: '${root.path}/settings',
        );
        final library = LegacyLibraryAdapter(backend: state);
        final session = LegacyConversionSession(state);
        try {
          await library.load();
          await library.savePatch({
            'check_after_import': false,
            'parallel_books': '1',
          });
          final long = StringBuffer();
          for (var c = 1; c <= 800; c++) {
            long.writeln('第$c章 标题');
            for (var l = 0; l < 100; l++) {
              long.writeln('这是合成正文，用于检验转换取消后的完整状态。章节$c，正文$l。');
            }
          }
          final files = [
            for (final name in ['已完成', '取消中', '未开始'])
              File('${root.path}/$name.txt'),
          ];
          files[0].writeAsStringSync('第一章 开始\n合成正文。\n');
          files[1].writeAsStringSync(long.toString());
          files[2].writeAsStringSync('第一章 末尾\n合成正文。\n');
          expect(
            (await library.importFiles(files.map((f) => f.path).toList()))
                .every((o) => o.succeeded),
            true,
          );
          final ids = library.books.value.map((b) => b.id).toList();
          final plan = await session.preview(
            ConversionRequest(
              books: ids,
              directory: '${root.path}/output',
              format: format,
              engine:
                  Platform.environment[format == 'KFX'
                      ? 'EASYPUB_TEST_BOKAI'
                      : 'EASYPUB_TEST_KINDLING']!,
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(plan.previewed, true);
          final running = session.commit(plan, acknowledgeWarnings: true);
          final wait = Stopwatch()..start();
          while (session.batch?.active?.bookId != ids[1] ||
              session.batch?.active?.job?.phase != 'converting') {
            if (!session.busy || wait.elapsedMilliseconds > 60000) {
              fail('Did not reach cancellable second book');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await session.cancel();
          final outputs = await running;
          expect(outputs.map((o) => o.phase), [
            'complete',
            'cancelled',
            'cancelled',
          ]);
          expect(
            session.batch!.items.any((i) => i.failed),
            false,
            reason: 'Cancelled work must not be retryable failure',
          );
          expect(session.batch!.hasFailedItems, false);
          expect(
            session.snapshot(session.batch!.items[1], null).phase,
            'cancelled',
            reason: 'Projection remains correct without task cache',
          );
          final taskCount = state.outputs.tasks.length;
          await session.batch!.retryFailed(() {});
          expect(
            state.outputs.tasks.length,
            taskCount,
            reason: 'Cancelled tasks excluded from failure retry',
          );
          final batchRecord = state.outputs.batchRecords.singleWhere(
            (b) => b['batch_id'] == session.batch!.batchId,
          );
          expect((batchRecord['items'] as List).map((i) => i['failed']), [
            false,
            false,
            false,
          ]);
          expect((batchRecord['items'] as List).map((i) => i['phase']), [
            'complete',
            'cancelled',
            'cancelled',
          ]);
          expect(await File(outputs.first.path).exists(), true);
          for (final o in outputs.skip(1)) {
            expect(await File(o.path).exists(), false);
          }
          // Simulate an old contradictory batch flag while keeping the native
          // terminal task history authoritative.
          final legacyRecord =
              jsonDecode(jsonEncode(batchRecord)) as Map<String, dynamic>;
          for (final item in (legacyRecord['items'] as List).cast<Map>()) {
            if (item['task_id'] != null) {
              item['failed'] = true;
              item.remove('phase');
            }
          }
          expect(await state.outputs.saveBatchRecord(legacyRecord), true);
          final reopened = PrototypeState(
            settingsDirectory: '${root.path}/settings',
          );
          try {
            expect(await reopened.loadGlobalSettings(), true);
            final restoredFeed = LegacyConversionSession(reopened);
            await restoredFeed.loadTaskFeed();
            restoredFeed.dispose();
            expect(reopened.outputs.tasks.map((t) => t.phase).toSet(), {
              'complete',
              'cancelled',
            });
            final restored = reopened.outputs.batchRecords.singleWhere(
              (b) => b['batch_id'] == session.batch!.batchId,
            );
            expect((restored['items'] as List).map((i) => i['phase']), [
              'complete',
              'cancelled',
              'cancelled',
            ]);
            expect(
              (restored['items'] as List).where((i) => i['failed'] == true),
              isEmpty,
            );
          } finally {
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
  test('native export failure remains failed and is not classified as cancellation', () async {
    final root = (await Directory(
      '../artifacts',
    ).createTemp('completion-native-failure-')).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final session = LegacyConversionSession(state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('${root.path}/变化.txt')
        ..writeAsStringSync('第一章 开始\n预览前的正文。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final plan = await session.preview(
        ConversionRequest(
          books: [state.currentId],
          directory: '${root.path}/output',
          format: 'MOBI',
          engine: Platform.environment['EASYPUB_TEST_KINDLING']!,
          generateCover: true,
          runChecks: false,
        ),
      );
      expect(plan.previewed, true);
      file.writeAsStringSync('第一章 开始\n预览后发生变化的正文。\n');
      final result = (await session.commit(
        plan,
        acknowledgeWarnings: true,
      )).single;
      expect(result.phase, 'failed');
      expect(session.batch!.items.single.failed, true);
      expect(session.batch!.hasFailedItems, true);
      expect(state.outputs.tasks.single.phase, 'failed');
      expect(await File(result.path).exists(), false);
      final record = (state.outputs.batchRecords.single['items'] as List).single;
      expect(record['failed'], true);
      expect(record['phase'], 'failed');
    } finally {
      session.dispose();
      library.dispose();
      state.dispose();
    }
  });
}
