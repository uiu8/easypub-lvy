import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';
// V21：旧原型的 createTextCover 已移除，改用书库与转换共用的生成封面。
import 'package:easypub_desktop/desk/library/generated_cover.dart'
    show renderGeneratedCover;

void main() {
  test(
    'failed batch persists original request and resolved publication',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = (await Directory(
        '../artifacts',
      ).createTemp('completion-retry-')).absolute;
      final state = PrototypeState(settingsDirectory: '${root.path}/settings');
      final library = LegacyLibraryAdapter(backend: state);
      var fail = true;
      final session = LegacyConversionSession(
        state,
        epubCall: (request) async {
          if (request['op'] == 'commit' && fail) {
            fail = false;
            throw const FormatException('模拟临时输出失败');
          }
          return (jsonDecode(
            await api.epubExportText(requestJson: jsonEncode(request)),
          ) as Map).cast<String, dynamic>();
        },
      );
      try {
        await library.load();
        await library.savePatch({'check_after_import': false});
        final source = File('${root.path}/甲.txt')
          ..writeAsStringSync('第一章 开始\n正文。\n');
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        final id = state.currentId;
        final plan = await session.preview(
          ConversionRequest(
            books: [id],
            directory: '${root.path}/original',
            format: 'EPUB',
            language: 'en',
            generateCover: true,
            runChecks: false,
          ),
        );
        expect(
          (await session.commit(plan, acknowledgeWarnings: true)).single.failed,
          true,
        );
        final record = state.outputs.batchRecords.single;
        expect(
          record['configuration'],
          isA<Map>(),
          reason: 'Retry needs original configuration, not session.request from another batch',
        );
        expect((record['configuration'] as Map)['language'], 'en');
        final item = (record['items'] as List).single as Map;
        expect(item['request'], isA<Map>());
        expect(item['input_fingerprint'], isA<String>());
        final firstTask = state.outputs.tasks.single.taskId;
        final originalPath = session.outputs.single.path;
        fail = true;
        final other = await session.preview(
          ConversionRequest(
            books: [id],
            directory: '${root.path}/other',
            format: 'EPUB',
            language: 'ja',
            generateCover: true,
            runChecks: false,
          ),
        );
        expect(
          (await session.commit(
            other,
            acknowledgeWarnings: true,
          )).single.failed,
          true,
        );
        final secondTask = state.outputs.tasks.last.taskId;
        await expectLater(
          session.previewRetry([firstTask, secondTask]),
          throwsA(isA<FormatException>()),
        );
        final project = '${root.path}/saved.easypub.json';
        expect((await library.saveProject(project)).succeeded, true);
        await library.savePatch({
          'default_language': 'zh-CN',
          'output_naming': 'filename',
        });
        final reopened = PrototypeState(
          settingsDirectory: '${root.path}/settings',
        );
        final restoredLibrary = LegacyLibraryAdapter(backend: reopened);
        final restored = LegacyConversionSession(reopened);
        try {
          await restoredLibrary.load();
          expect((await restoredLibrary.openProject(project)).succeeded, true);
          final retry = await restored.previewRetry([firstTask]);
          expect(retry.previewed, true);
          expect(restored.request!.directory, '${root.path}/original');
          expect(restored.request!.language, 'en');
          expect(restored.request!.runChecks, false);
          expect(retry.outputs.single.path, originalPath);
          final result = (await restored.commit(
            retry,
            acknowledgeWarnings: true,
          )).single;
          expect(result.complete, true, reason: result.detail);
          final epub = await readBook(result.path, () => false);
          expect((epub.resourceReport!['metadata'] as Map)['language'], 'en');
          expect(
            reopened.outputs.tasks.where((t) => t.phase == 'complete').length,
            1,
          );
          expect(
            reopened.outputs.batchRecords.last['retry_of_batch_id'],
            record['batch_id'],
          );

          // Valid image bytes changed at the same path must invalidate the recipe.
          final secondBatch = reopened.outputs.tasks
              .singleWhere((t) => t.taskId == secondTask)
              .batchId;
          final secondRecord = reopened.outputs.batchRecords.singleWhere(
            (r) => r['batch_id'] == secondBatch,
          );
          final secondItem = (secondRecord['items'] as List).single as Map;
          final frozenSettings =
              ((secondItem['request'] as Map)['publication'] as Map)['settings']
                  as Map;
          final cover = File(frozenSettings['cover_path'] as String);
          final originalCover = await cover.readAsBytes();
          final replacement = await renderGeneratedCover(
            '不同封面',
            '合成作者',
            Directory('${root.path}/alternate-cover'),
          );
          try {
            await cover.writeAsBytes(await File(replacement).readAsBytes());
            await expectLater(
              restored.previewRetry([secondTask]),
              throwsA(
                isA<FormatException>().having(
                  (e) => e.message,
                  'reason',
                  contains('原稿、资源或转换器'),
                ),
              ),
            );
          } finally {
            await cover.writeAsBytes(originalCover);
          }
          final originalSource = source.readAsBytesSync();
          try {
            source.writeAsStringSync('第一章 新内容\n原文件已变化。\n');
            var blocked = false;
            try {
              blocked = !(await restored.previewRetry([secondTask])).previewed;
            } on FormatException {
              blocked = true;
            }
            expect(
              blocked,
              true,
              reason: 'Changed source must not replay the old attempt',
            );
          } finally {
            source.writeAsBytesSync(originalSource);
          }
          // A changed draft cannot silently reuse the old recipe.
          final info = restoredLibrary.openBookInformation(id);
          await info.apply(await info.preview({'author': '新作者'}));
          info.dispose();
          await expectLater(
            restored.previewRetry([secondTask]),
            throwsA(isA<FormatException>()),
          );
          // Old records lacking a recipe must never borrow the latest session request.
          final legacy = Map<String, dynamic>.from(record)
            ..remove('configuration');
          expect(await reopened.outputs.saveBatchRecord(legacy), true);
          await expectLater(
            restored.previewRetry([firstTask]),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                contains('旧批次缺少'),
              ),
            ),
          );
        } finally {
          restored.dispose();
          restoredLibrary.dispose();
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
