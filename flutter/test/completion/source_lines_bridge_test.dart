import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/infrastructure/source_excerpt.dart';

import 'library_removal_test.dart' as fixtures;

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test('长中文行跨桥接续读不丢字节，摘录明确标记两种截断', () async {
    final (state, library, root) = await fixtures.fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    for (final exact in [false, true]) {
      final long = exact ? 'A' * (256 * 1024) : '汉字𠮷' * 40000;
      final file = File('$root/long-$exact.txt')
        ..writeAsStringSync('$long\n结束。');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final source = state.current.source!;
      var page = await api.readSourceLines(
        sourceId: source.sourceId,
        revision: source.revision,
        lineIndex: 0,
        utf8Column: 0,
        limit: 3,
      );
      expect(page.lines.first.continues, !exact);
      expect(page.nextLineIndex, exact ? 1 : 0);
      expect(
        page.nextUtf8Column,
        exact ? 0 : utf8.encode(page.lines.first.text).length,
      );
      final lines = <int, String>{};
      var reads = 0;
      while (true) {
        expect(++reads, lessThan(5));
        for (final line in page.lines) {
          final previous = lines[line.lineNumber] ?? '';
          expect(line.utf8Column, utf8.encode(previous).length);
          lines[line.lineNumber] = previous + line.text;
        }
        if (page.nextLineIndex == null) break;
        page = await api.readSourceLines(
          sourceId: source.sourceId,
          revision: source.revision,
          lineIndex: page.nextLineIndex!,
          utf8Column: page.nextUtf8Column!,
          limit: 3,
        );
      }
      expect(lines[1], long);
      expect(lines[2], '结束。');
      final excerpt = await sourceExcerpt(
        sourceId: source.sourceId,
        revision: source.revision,
        lineIndex: 0,
        limit: 3,
      );
      expect(excerpt, contains(exact ? '〔摘录达到显示上限，后续未展示〕' : '〔本行过长，后续未展示〕'));
    }
  });
}
