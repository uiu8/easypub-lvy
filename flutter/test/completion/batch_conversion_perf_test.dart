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
      for (var i = 0; i < 50; i++) {
        final file = File('${root.path}/样本$i.txt');
        final text = StringBuffer();
        for (var chapter = 1; chapter <= 30; chapter++) {
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
          await info.preview({'language': 'zh-CN', 'author': '合成作者'}),
        );
        info.dispose();
        ids.add(id);
        sources.add(file.path);
      }
      final reports = <Map<String, Object?>>[];
      for (final count in [10, 50]) {
        for (final parallel in [1, 4]) {
          final dir = await Directory('${root.path}/$count-$parallel').create();
          final batch = OutputBatch(state, ids.take(count))
            ..parallelOverride = parallel
            ..checksEnabled = false;
          for (var i = 0; i < count; i++) {
            batch.items[i].path = '${dir.path}/样本$i.epub';
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
          expect(batch.items.every((item) => item.preview != null), true);
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
            'count': count,
            'parallel': parallel,
            'peak_active': peak,
            'preview_ms': previewMs,
            'commit_ms': commitMs,
          });
        }
      }
      await File('${root.path}/report.json').writeAsString(
        jsonEncode({
          'runs': reports,
          'representative': [
            for (var i = 0; i < 3; i++)
              {
                'source': sources[i],
                'epub': '${root.path}/10-4/样本$i.epub',
                'title': '样本$i',
              },
          ],
        }),
      );
    },
    skip: Platform.environment['EASYPUB_B8_PERF'] != '1',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
