import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/output_batch.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'B8 真实 EPUB 批量 10/50 本与并发 1/4 基线',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = (await Directory('../artifacts').createTemp('b8-batch-'))
          .absolute;
      final state = PrototypeState(settingsDirectory: '${root.path}/settings');
      final library = LegacyLibraryAdapter(backend: state);
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      await library.load();
      await library.savePatch({'check_after_import': false});
      final ids = <String>[];
      final sources = <String>[];
      final cover = await File('../samples/b7-covers/transparent.png')
          .copy('${root.path}/cover.png');
      // R6：可指定每本章数与样书本数，测大书。
      final chapters = int.parse(
        Platform.environment['EASYPUB_B8_CHAPTERS'] ?? '30',
      );
      final books = int.parse(Platform.environment['EASYPUB_B8_BOOKS'] ?? '50');
      for (var i = 0; i < books; i++) {
        final file = File('${root.path}/样本$i.txt');
        final text = StringBuffer();
        for (var chapter = 1; chapter <= chapters; chapter++) {
          if (i % 3 == 2 && chapter % 10 == 1) {
            text.writeln('第${chapter ~/ 10 + 1}卷 卷名');
          }
          text.writeln('第$chapter章 测量$i');
          text.writeln(
            i % 3 == 1
                ? '混合字符😀 é α 中文，编号 $i-$chapter。' * 20
                : '合成小说正文，第$i本第$chapter章。' * 20,
          );
        }
        await file.writeAsString(text.toString());
        expect((await library.importFiles([file.path])).single.succeeded, true);
        final id = state.currentId;
        final info = library.openBookInformation(id);
        await info.apply(
          await info.preview({
            'language': 'zh-CN',
            'author': '合成作者',
            // AZW3/KFX 要求有封面（R6 起本测量也覆盖这两种格式）。
            'cover_path': cover.path,
          }),
        );
        info.dispose();
        ids.add(id);
        sources.add(file.path);
      }
      final reports = <Map<String, Object?>>[];
      // R6：可用环境变量指定格式、本数与并发；默认仍是 EPUB、10/50 本、并发 1/4。
      List<String> list(String name, String fallback) =>
          (Platform.environment[name] ?? fallback).split(',');
      for (final format in list('EASYPUB_B8_FORMATS', 'EPUB')) {
        for (final count in list('EASYPUB_B8_COUNTS', '10,50').map(int.parse)) {
          for (final parallel in list(
            'EASYPUB_B8_PARALLEL',
            '1,4',
          ).map(int.parse)) {
            final ext = format.toLowerCase();
            final dir = await Directory('${root.path}/$format-$count-$parallel')
                .create();
            final batch = OutputBatch(state, ids.take(count))
              ..parallelOverride = parallel
              ..checksEnabled = false
              ..format = format
              ..engine = switch (format) {
                'KFX' => Platform.environment['EASYPUB_TEST_BOKAI'] ?? '',
                'EPUB' => '',
                _ => Platform.environment['EASYPUB_TEST_KINDLING'] ?? '',
              };
            for (var i = 0; i < count; i++) {
              batch.items[i].path = '${dir.path}/样本$i.$ext';
            }
            var peak = 0;
            void changed() {
              peak = math.max(
                peak,
                batch.items
                    .where(
                      (i) => [
                        'preparing',
                        'prepared',
                        'converting',
                        'checking',
                        'publishing',
                      ].contains(i.phase),
                    )
                    .length,
              );
            }

            final clock = Stopwatch()..start();
            await batch.previewAll(changed);
            final previewMs = clock.elapsedMilliseconds;
            expect(
              batch.items.every((item) => item.preview != null),
              true,
              reason:
                  '$format: ${batch.items.map((i) => i.status).toSet().join(" | ")}',
            );
            clock.reset();
            await batch.commitAll(changed);
            final commitMs = clock.elapsedMilliseconds;
            expect(
              batch.items.every((item) => item.phase == 'complete'),
              true,
              reason: batch.items.map((i) => i.status).join('\n'),
            );
            expect(peak, lessThanOrEqualTo(parallel));
            reports.add({
              'format': format,
              'count': count,
              'parallel': parallel,
              'peak_active': peak,
              'preview_ms': previewMs,
              'commit_ms': commitMs,
            });
          }
        }
      }
      await File('${root.path}/report.json').writeAsString(
        jsonEncode({
          'runs': reports,
          'representative': [
            for (var i = 0; i < 3; i++)
              {
                'source': sources[i],
                'epub': '${root.path}/EPUB-10-4/样本$i.epub',
                'title': '样本$i',
              },
          ],
        }),
      );
    },
    skip: Platform.environment['EASYPUB_B8_PERF'] != '1',
    timeout: const Timeout(Duration(minutes: 60)),
  );
}
