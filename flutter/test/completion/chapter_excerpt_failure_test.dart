import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/chapters/manuscript.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class ExcerptSession extends Fake implements ChapterSession {
  final reads = <Completer<ChapterBody>>[];

  @override
  Future<ChapterBody> body(ChapterPage page, String nodeId, int offset) {
    final result = Completer<ChapterBody>();
    reads.add(result);
    return result.future;
  }
}

void main() {
  testWidgets('摘录失败不重复读取，刷新可重试，旧请求不覆盖新章', (t) async {
    final session = ExcerptSession();
    Future<void> show(String guard) => t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChapterManuscript(
            session: session,
            page: ChapterPage(const [], 1, 0, guard),
            node: const ChapterNode('chapter', '第一章', 'chapter', 0, 1, true),
            initialBody: const ChapterBody(['已读正文'], 0, 1, false),
          ),
        ),
      ),
    );
    await show('first');
    await t.pumpAndSettle();
    final dynamic state = t.state(find.byType(ChapterManuscript));
    final Future<void> failed = state.readSegmentText(<int>[20]);
    session.reads.single.completeError(StateError('fixture read failure'));
    await failed;
    await t.pump();
    expect(state.segmentText[20], '');
    await state.readSegmentText(<int>[20]);
    expect(session.reads, hasLength(1));

    await show('second');
    expect(state.segmentText, isEmpty);
    final Future<void> oldRead = state.readSegmentText(<int>[20]);
    await show('third');
    final Future<void> newRead = state.readSegmentText(<int>[20]);
    session.reads[1].complete(const ChapterBody(['过期摘录'], 19, 20, false));
    await oldRead;
    expect(state.segmentText, isEmpty);
    expect(state.segmentReading, true);
    session.reads[2].complete(const ChapterBody(['刷新后的摘录'], 19, 20, false));
    await newRead;
    await t.pumpAndSettle();
    expect(state.segmentText[20], '刷新后的摘录');
    expect(state.segmentReading, false);
    expect(t.takeException(), isNull);
  });
}
