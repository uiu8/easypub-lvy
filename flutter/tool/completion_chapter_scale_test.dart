import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/chapter_service.dart';

import '../test/completion/library_removal_test.dart' as fixtures;

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test('1000 and 10000 chapter traversal reaches exact last body and preserves source', () async {
    final (state, library, root) = await fixtures.fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final reports = <Map<String, Object>>[];
    final counts =
        Platform.environment['EASYPUB_SCALE_COUNTS']
            ?.split(',')
            .map(int.parse)
            .toList() ??
        [1000, 10000];
    for (final count in counts) {
      final text = List.generate(
        count,
        (i) =>
            '${i % 100 == 0 ? '第${i ~/ 100 + 1}卷 卷名\n' : ''}第${i + 1}章 标题${i + 1}\n独立正文${i + 1}。\n',
      ).join();
      final file = File('$root/$count.txt');
      await file.writeAsString(text);
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = library.books.value.firstWhere((b) => b.path == file.path).id;
      final session = library.openChapters(id);
      final watch = Stopwatch()..start();
      var calls = 0;
      final nodes = <ChapterNode>[];
      late ChapterPage page;
      final paged = Platform.environment['EASYPUB_SCALE_PAGED'] == '1';
      if (paged) {
        do {
          page = await session.read(nodes.length);
          calls++;
          nodes.addAll(page.nodes);
        } while (nodes.length < page.total);
      } else {
        page = await (session as ChapterOutlineSession).readOutline();
        calls++;
        nodes.addAll(page.nodes);
        expect(
          identical(
            await (session as ChapterOutlineSession).readOutline(),
            page,
          ),
          true,
        );
      }
      final elapsed = watch.elapsedMilliseconds;
      expect(nodes.length, count + (count + 99) ~/ 100);
      expect(nodes.last.title, '第$count章 标题$count');
      expect(nodes.map((n) => n.id).toSet().length, nodes.length);
      expect(
        (await session.body(page, nodes.last.id, 0)).lines.join('\n'),
        contains('独立正文$count'),
      );
      expect(await file.readAsString(), text);
      final report = <String, Object>{
        'chapters': count,
        'nodes': nodes.length,
        'calls': calls,
        'elapsed_ms': elapsed,
        'rss_bytes': ProcessInfo.currentRss,
        'peak_rss_bytes': ProcessInfo.maxRss,
      };
      reports.add(report);
      stdout.writeln('chapter68 ${jsonEncode(report)}');
      if (!paged) {
        final oldLast = nodes.last;
        await session.confirm(
          await session.preview(
            page,
            RenameChapter(oldLast.id, '第$count章 修改后末章'),
          ),
        );
        final changed = await (session as ChapterOutlineSession).readOutline();
        expect(identical(changed, page), false);
        expect(changed.nodes.last.id, oldLast.id);
        expect(changed.nodes.last.title, '第$count章 修改后末章');
        await session.history(changed, undo: true);
        final restored = await (session as ChapterOutlineSession).readOutline();
        expect(restored.nodes.last.title, oldLast.title);
        expect(restored.nodes.last.id, oldLast.id);
      }
    }
    await File(
      Platform.environment['EASYPUB_SCALE_REPORT'] ??
          '../artifacts/completion-chapter68-metrics-${Platform.environment['EASYPUB_SCALE_PAGED'] == '1' ? 'paged' : 'after'}.json',
    ).writeAsString(jsonEncode(reports));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
