import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/checks/check_board.dart';

class SwitchChecks extends Fake
    implements BookCheckSession, CheckUpdateSession {
  @override
  final ChangeNotifier changes = ChangeNotifier();
  @override
  BookCheckReport get shown =>
      const BookCheckReport('same-guard', [], null, '', 0);
  @override
  bool isCurrent(BookCheckReport report) => true;
  @override
  bool rulesCurrent(String id) => true;
  @override
  List<CheckFinding> metadataFindings() => [];
  @override
  Set<int> keptCleanupLines() => {};
  @override
  String get cleanupRulesKey => '';
  @override
  Future<CheckSpots?> storedSpots() async => null;
  @override
  void dispose() => changes.dispose();
}

class SwitchChapters extends Fake
    implements ChapterSession, ChapterIssueQueueSession {
  final requests = <Completer<ChapterIssuePage>>[];
  @override
  Future<ChapterPage> read(
    int offset, {
    bool includeBody = false,
    String? preferredNodeId,
  }) async => const ChapterPage([], 1, 0, 'same-guard');
  @override
  Future<Int32List> issueQueue(ChapterPage page) async =>
      Int32List.fromList([0]);
  @override
  Future<ChapterIssuePage> issues(
    ChapterPage page,
    int offset, {
    bool effective = false,
  }) {
    final pending = Completer<ChapterIssuePage>();
    requests.add(pending);
    return pending.future;
  }
}

class SwitchLibrary extends Fake implements LibraryService {
  final sessions = <SwitchChapters>[];
  @override
  BookCheckSession openChecks(String id) => SwitchChecks();
  @override
  ChapterSession openChapters(String id) {
    final session = SwitchChapters();
    sessions.add(session);
    return session;
  }
}

void main() {
  testWidgets('检查问题页跨书 A-B-A 隔离旧成功、旧失败与同页在途请求', (t) async {
    final library = SwitchLibrary();
    final board = CheckBoard(
      library: library,
      go: (_) {},
      location: () => Uri.parse('/'),
      showChapterIssue: (_, _, _) {},
      showChecks: (_, _) {},
    );
    addTearDown(board.dispose);
    ChapterIssuePage result(String id) => ChapterIssuePage(
      [
        ChapterIssue(
          id,
          'duplicate-content',
          id,
          '',
          const [],
          null,
          false,
          false,
        ),
      ],
      1,
      0,
    );
    board.enter('A', '章节编辑');
    await t.pump();
    final oldA = board.issueAt(0);
    board.enter('B', '章节编辑');
    await t.pump();
    final oldB = board.issueAt(0);
    board.enter('A', '章节编辑');
    await t.pump();
    final current = board.issueAt(0);
    final duplicate = board.issueAt(0);
    expect(library.sessions, hasLength(3));
    expect(library.sessions.last.requests, hasLength(1));
    library.sessions[0].requests.single.complete(result('old-A'));
    library.sessions[1].requests.single.completeError(
      StateError('old B failure'),
    );
    expect(await oldA, isNull);
    expect(await oldB, isNull);
    library.sessions[2].requests.single.complete(result('new-A'));
    expect((await current)?.id, 'new-A');
    expect((await duplicate)?.id, 'new-A');
    expect((await board.issueAt(0))?.id, 'new-A');
    expect(library.sessions.last.requests, hasLength(1));
  });
}
