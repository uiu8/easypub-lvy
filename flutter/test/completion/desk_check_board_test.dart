import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/application/cleanup_rule_resolution.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/checks/check_board.dart';
import 'package:easypub_desktop/desk/checks/cleanup_findings.dart';
import 'package:easypub_desktop/infrastructure/check_report_cache.dart';
import 'package:easypub_desktop/infrastructure/legacy_book_check_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_rule_catalog_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _NoPicker extends Fake implements BookFilePicker {}

var _bridgeReady = false;
Future<void> _initBridge() async {
  if (_bridgeReady) return;
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(
      Platform.environment['EASYPUB_TEST_DLL']!,
    ),
  );
  _bridgeReady = true;
}

class _Harness {
  _Harness(this.t, this.library, this.state, this.bookId, this.settings);
  final WidgetTester t;
  final LegacyLibraryAdapter library;
  final PrototypeState state;
  final String bookId, settings;
  late GoRouter router;
  late CheckBoard board;
  String get book => Uri.encodeComponent(bookId);
  Uri get uri => router.routerDelegate.currentConfiguration.uri;

  Future<void> settle([int rounds = 60]) async {
    for (var i = 0; i < rounds; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> until(bool Function() ok, {int rounds = 400}) async {
    for (var i = 0; i < rounds && !ok(); i++) {
      await settle(2);
    }
    expect(ok(), true);
  }

  Future<void> go(String page) async {
    router.go('/books/$book/$page');
    await settle();
  }

  Future<void> tap(String key) async {
    await t.tap(find.byKey(ValueKey(key)));
    await settle();
  }

  bool has(String key) => find.byKey(ValueKey(key)).evaluate().isNotEmpty;
  String get title =>
      t.widget<Text>(find.byKey(const ValueKey('check-bar-title'))).data!;

  /// 上面列表里选中的那一条。
  String get listed =>
      t.widget<Text>(find.byKey(const ValueKey('issue-title'))).data!;
}

Future<_Harness> _open(
  WidgetTester t, {
  Size size = const Size(1500, 900),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (call) async => call.method == 'isMaximized' ? false : null,
  );
  late LegacyLibraryAdapter library;
  late PrototypeState state;
  late String bookId;
  late String settings;
  await t.runAsync(() async {
    await _initBridge();
    final tmp = await Directory('../artifacts').createTemp('check-board-');
    settings = '${tmp.absolute.path}/settings';
    state = PrototypeState(settingsDirectory: settings);
    library = LegacyLibraryAdapter(backend: state);
    await library.load();
    await library.savePatch({'check_after_import': false});
    final body = StringBuffer();
    for (final n in [1, 2, 3, 5, 6, 8]) {
      body.writeln('第$n章 云涌');
      for (var i = 0; i < 6; i++) {
        body.writeln('　　这是第$n章的第$i段正文，山路很长，海风很轻。');
      }
      body.writeln('这一行的末尾留着几个空格。   ');
    }
    final file = File('${tmp.absolute.path}/山海之间.txt')
      ..writeAsStringSync(body.toString());
    expect((await library.importFiles([file.path])).single.succeeded, true);
    bookId = library.books.value.single.id;
  });
  addTearDown(() {
    library.dispose();
    state.dispose();
  });
  library.selectBook(bookId);
  final h = _Harness(t, library, state, bookId, settings);
  await t.pumpWidget(RewriteApp(library: library, picker: _NoPicker()));
  await h.settle();
  final context = t.element(find.byKey(const ValueKey('workspace-output-bar')));
  h.router = GoRouter.of(context);
  h.board = CheckBoardScope.maybeOf(context)!;
  return h;
}

void main() {
  testWidgets('去处理到问题页签，核实后走下一条，走到头才换段，回到检查停在原处', (t) async {
    final h = await _open(t);
    final board = h.board;

    // 没检查过：什么都不显示，也不替用户跑检查。
    await h.go('chapters');
    expect(h.has('check-bar'), false);
    expect(
      Directory('${h.settings}/check-reports').existsSync() &&
          Directory('${h.settings}/check-reports').listSync().isNotEmpty,
      false,
      reason: '不能偷偷跑检查',
    );

    await h.go('checks');
    await h.until(() => h.has('check-bar') && h.has('issue-go'));
    final chapters = board.trackOf('chapters')!;
    expect(chapters.pending, 2);

    // 检查页也是双向的：下面走，列表走；列表点，下面走。
    await h.tap('check-bar-step');
    await h.until(() => h.title.contains('第6章后直接到了第8章'));
    await h.until(() => h.listed.contains('第6章后直接到了第8章'));
    await t.tap(find.text('第3章后直接到了第5章').first);
    await h.settle();
    await h.until(() => h.title.contains('第3章后直接到了第5章'));
    expect(find.byKey(const ValueKey('checks-tab-chapters')), findsOneWidget);
    expect(find.byKey(const ValueKey('checks-tab-cleanup')), findsOneWidget);
    expect(h.has('check-bar-back'), false, reason: '检查页本身不用回');
    expect(find.text('定位章节'), findsNothing, reason: '检查页只看');

    // 章节问题直达“问题”页签，选中点的那一条。
    await h.tap('issue-go');
    await h.until(() => h.uri.path.endsWith('/chapters'));
    expect(h.uri.queryParameters['issues'], 'true');
    await h.until(() => find.text('预览处理').evaluate().isNotEmpty);
    expect(h.has('check-bar-back'), true);
    expect(board.selected?.track, 'chapters');
    expect(h.title, contains('第3章后直接到了第5章'));
    expect(h.has('issue-position'), false, reason: '进度条就是导航，不再放第二条');

    // 下一条就地选中，地址不变。
    final before = h.uri.toString();
    expect(h.listed, contains('第3章后直接到了第5章'));
    await h.tap('check-bar-step');
    await h.until(() => h.title.contains('第6章后直接到了第8章'));
    expect(h.uri.toString(), before);
    await h.until(() => h.listed.contains('第6章后直接到了第8章'));

    // 反过来：点上面的列表，下面跟着走。
    await t.tap(find.text('第3章后直接到了第5章').first);
    await h.settle();
    expect(h.listed, contains('第3章后直接到了第5章'));
    await h.until(() => h.title.contains('第3章后直接到了第5章'));
    await h.tap('check-bar-step');
    await h.until(() => h.listed.contains('第6章后直接到了第8章'));

    // 核实：做完加一，这一段走到头，按钮变成去下一段。
    expect(find.text('核实无误'), findsOneWidget);
    final total = board.trackOf('chapters')!.total;
    await h.tap('check-bar-action');
    await h.until(() => board.trackOf('chapters')!.done == 1);
    expect(board.trackOf('chapters')!.total, total, reason: '总数不变');
    expect(h.uri.toString(), before, reason: '不自动换页');

    await h.tap('check-bar-prev');
    await h.until(() => h.title.contains('第3章后直接到了第5章'));
    await h.tap('check-bar-action');
    await h.until(() => board.trackOf('chapters')!.pending == 0);
    expect(h.uri.path, endsWith('/chapters'));
    expect(h.has('check-bar-next-track'), true);
    expect(find.textContaining('去文本'), findsOneWidget);

    // 换段才到文本清理页，那里的上一处、下一处收起来。
    await h.tap('check-bar-next-track');
    await h.until(() => h.uri.path.endsWith('/cleanup'));
    await h.until(() => board.selected?.track == 'cleanup');
    await h.settle(120);
    expect(h.has('check-bar-action'), true, reason: '站在文本问题上，能保留原文');
    expect(find.text('下一处'), findsNothing);
    expect(board.pageLineAt(0), isNotNull);
    await h.until(() => h.title == '行尾空白' || h.title.isNotEmpty);

    // 单独走到别的页面：不再站在上一页的问题上。
    await h.go('information');
    await h.until(() => board.selected == null);
    await h.go('cleanup');
    await h.until(() => h.has('check-bar'));
    await h.tap('check-bar-step');
    await h.until(() => board.selected?.track == 'cleanup');

    // 回到检查：停在文本清理页签。
    await h.tap('check-bar-back');
    await h.until(() => h.uri.path.endsWith('/checks'));
    await h.until(() => h.has('cleanup-findings'));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('改书籍信息只更新信息，填好进度立刻往前走；改书稿后章节数字自己变', (t) async {
    final h = await _open(t);
    final board = h.board;
    await h.go('checks');
    await h.until(() => h.has('check-bar') && h.has('issue-go'));
    final session = h.library.openChecks(h.bookId);
    addTearDown(session.dispose);
    final update = session as CheckUpdateSession;
    final report = update.shown!;
    expect(
      report.guards.keys,
      containsAll(['chapters', 'cleanup', 'metadata']),
    );
    final metadata = board.trackOf('metadata')!;
    expect(metadata.pending, greaterThan(0));

    // 信息问题：跳过去高亮，填好不用等检查。
    await h.go('information?focus=language');
    await h.until(
      () => find
          .byKey(const ValueKey('information-problem-language'))
          .evaluate()
          .isNotEmpty,
    );
    await t.enterText(
      find.byKey(const ValueKey('information-language')),
      'zh-CN',
    );
    await h.settle(80);
    expect(
      find.byKey(const ValueKey('information-problem-language')),
      findsNothing,
    );
    await h.until(() => board.trackOf('metadata')!.done == 1);
    expect(board.trackOf('metadata')!.total, metadata.total);

    // 章节和文本没有重算：还是同一个对象。
    await h.until(() => update.domainCurrent('metadata'));
    await h.until(() => session.isCurrent(update.shown!));
    final after = update.shown!;
    expect(
      identical(
        after.domains.firstWhere((d) => d.id == 'chapters'),
        report.domains.firstWhere((d) => d.id == 'chapters'),
      ),
      true,
      reason: '改信息不重算章节',
    );
    expect(
      identical(
        after.domains.firstWhere((d) => d.id == 'cleanup'),
        report.domains.firstWhere((d) => d.id == 'cleanup'),
      ),
      true,
      reason: '改信息不重算文本',
    );

    // 改书稿：不用点检查，问题数自己变。
    await h.go('chapters');
    await h.until(() => h.has('check-bar'));
    final pending = board.trackOf('chapters')!.pending;
    await t.runAsync(() async {
      final chapters = h.library.openChapters(h.bookId);
      final page = await chapters.read(0);
      final node = page.nodes.firstWhere((n) => n.title.contains('第8章'));
      await chapters.rename(page, node.id, '第7章 云涌');
    });
    await h.until(() => board.trackOf('chapters')!.pending != pending);
    expect(board.trackOf('chapters')!.total, greaterThanOrEqualTo(pending));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('关掉后这次不再出现，F8 叫回来；窄窗口不溢出', (t) async {
    final h = await _open(t, size: const Size(1100, 720));
    final board = h.board;
    await h.go('checks');
    await h.until(() => h.has('check-bar'));
    await h.go('cleanup');
    await h.until(() => h.has('check-bar'));
    await h.tap('check-bar-close');
    expect(h.has('check-bar'), false);
    await h.go('chapters');
    expect(h.has('check-bar'), false);
    board.reopenOrStep(h.bookId, 1);
    await h.settle(10);
    expect(h.has('check-bar'), true);
    t.view.physicalSize = const Size(700, 720);
    await h.settle(10);
    expect(h.has('check-bar'), true);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('清理页点选一处进度条跟随；保留算做完；改规则从头算', (t) async {
    final h = await _open(t);
    final board = h.board;
    await h.go('checks');
    await h.until(() => h.has('check-bar') && h.has('issue-go'));
    await h.go('cleanup');
    await h.until(() => board.pageLineAt(0) != null);
    await h.until(() => find.text('本次结果').evaluate().isNotEmpty);
    final total = board.trackOf('cleanup')!.total;
    expect(total, 6);

    // 点选第 3 处：进度条跟过来，地址不变。
    final line = board.pageLineAt(2)!;
    final before = h.uri.toString();
    await h.tap('cleanup-change-$line');
    expect(board.selected, (track: 'cleanup', index: 2));
    expect(h.uri.toString(), before);
    expect(h.title, contains('行尾空白'));

    // 反过来：下面走，页面选中的那一行跟着走（当前行不再用这个键）。
    await h.tap('check-bar-step');
    await h.until(() => board.selected?.index == 3);
    final next = board.pageLineAt(3)!;
    await h.until(() => !h.has('cleanup-change-$next'));
    expect(h.has('cleanup-change-$line'), true);
    await h.tap('check-bar-prev');
    await h.until(() => !h.has('cleanup-change-$line'));

    // 在页面上点“保留原文”：进度也走。
    await t.tap(find.text('保留原文').first);
    await h.until(() => board.trackOf('cleanup')!.done == 1);
    expect(board.trackOf('cleanup')!.total, total);

    // 规则还是草稿：按草稿算，这一批是新的。
    Finder rule() => find
        .ancestor(of: find.text('去掉每行末尾的空格'), matching: find.byType(InkWell))
        .first;
    await t.tap(rule());
    await h.until(() => board.trackOf('cleanup') == null);

    // 改回来：又回到原来的问题和进度。
    await h.settle(30);
    await t.tap(rule());
    await h.until(() => board.trackOf('cleanup')?.done == 1);
    expect(board.trackOf('cleanup')!.total, total);

    // 规则保存下来：不用点检查，进度基数跟着变。
    final session = h.library.openChecks(h.bookId);
    addTearDown(session.dispose);
    final update = session as CheckUpdateSession;
    expect(update.shown!.baseline['cleanup'], total);
    await t.runAsync(
      () => h.library.savePatch({
        'automatic_cleanup_pipeline': [
          {'kind': 'collapse_blank_lines'},
        ],
      }),
    );
    await h.until(() => update.shown!.domains.any((d) => d.id == 'cleanup'));
    await h.until(() => session.isCurrent(update.shown!));
    expect(update.shown!.baseline['cleanup'], 0, reason: '换了规则就从头算');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('检查页的文本和信息页签、信息页也是双向的', (t) async {
    final h = await _open(t);
    final board = h.board;
    await h.go('checks');
    await h.until(() => h.has('check-bar') && h.has('issue-go'));

    // 文本页签：下面走到第 3 处，列表标出那一行；点列表另一行，下面跟过去。
    await h.tap('checks-tab-cleanup');
    await h.until(() => h.has('cleanup-findings'));
    await h.until(() => board.selected?.track == 'cleanup');
    await h.until(() => board.selectedCheckLine != null);
    await h.tap('check-bar-step');
    await h.tap('check-bar-step');
    await h.until(() => board.selected?.index == 2);
    final line = board.selectedCheckLine!;
    bool marked(int at) =>
        t
            .widget<CleanupFindingsView>(
              find.byKey(const ValueKey('cleanup-findings')),
            )
            .selectedLine ==
        at;
    expect(marked(line), true);
    final other = t
        .widget<CleanupFindingsView>(
          find.byKey(const ValueKey('cleanup-findings')),
        )
        .items
        .first
        .line;
    await t.tap(
      find.byKey(ValueKey('cleanup-finding-$other-trim_trailing_spaces')),
    );
    await h.settle(10);
    expect(board.selected?.index, 0);
    expect(marked(other), true);

    // 信息页签：点卡片，下面跟过去；下面走，卡片跟着。
    await h.tap('checks-tab-metadata');
    await h.until(() => board.selected?.track == 'metadata');
    await t.tap(find.text('尚未指定封面'));
    await h.settle(10);
    expect(board.selectedFindingId, 'metadata:cover');
    await h.tap('check-bar-prev');
    await h.until(() => board.selectedFindingId != 'metadata:cover');

    // 信息页：点有问题的输入框，下面跟过去。
    await h.go('information');
    await h.until(() => h.has('check-bar'));
    await t.tap(find.byKey(const ValueKey('information-language')));
    await h.settle(10);
    expect(board.selectedFindingId, 'metadata:language');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('关掉检查后那一段跟着消失，不算做完；打开又回来', (t) async {
    final h = await _open(t);
    final board = h.board;
    await h.go('checks');
    await h.until(() => h.has('check-bar') && h.has('issue-go'));
    await h.go('chapters');
    await h.until(() => h.has('check-bar'));
    expect(board.trackOf('metadata'), isNotNull);
    expect(board.trackOf('chapters')!.total, 2);
    final rules = LegacyRuleCatalogService(h.state, h.bookId);
    addTearDown(rules.dispose);
    Future<void> toggle(Map<String, bool> changes) => t.runAsync(() async {
      final plan = await rules.previewToggles([
        for (final e in changes.entries) {'id': e.key, 'enabled': e.value},
      ]);
      await rules.applyToggles(plan['plan_id'] as String);
    });

    // 书籍信息：一项一项关，全关后这一段消失，不留“已做完”。
    await toggle({'preflight.cover': false});
    await h.until(
      () =>
          board.trackOf('metadata')?.pending == 2 ||
          board.trackOf('metadata')?.pending == 1,
    );
    expect(board.trackOf('metadata')!.done, 0, reason: '关掉的不算做完');
    await toggle({'preflight.language': false, 'preflight.author': false});
    await h.until(() => board.trackOf('metadata') == null);
    await h.settle(80);
    expect(board.trackOf('metadata'), isNull, reason: '后台更新后也不回来');

    // 章节检查关掉：这一段也消失。
    await toggle({'check.number_gap': false});
    await h.until(() => board.trackOf('chapters') == null);

    // 检查页的页签数字跟着变。
    await h.go('checks');
    await h.settle(60);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('checks-tab-metadata')),
        matching: find.text('3'),
      ),
      findsNothing,
    );

    // 打开：问题回来，进度从头算。
    await toggle({'preflight.cover': true, 'check.number_gap': true});
    await h.until(() => board.trackOf('metadata')?.pending == 1);
    await h.until(() => board.trackOf('chapters')?.pending == 2);
    expect(board.trackOf('chapters')!.done, 0);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('重启后文本位置读文件，文件坏了重新算', (t) async {
    final h = await _open(t);
    await h.go('checks');
    await h.until(() => h.has('check-bar') && h.has('issue-go'));
    final session = h.library.openChecks(h.bookId);
    addTearDown(session.dispose);
    final update = session as CheckUpdateSession;
    final first = await t.runAsync(update.spots);
    expect(first!.length, greaterThan(0));
    final dir = Directory('${h.settings}/check-reports');
    final stored = dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.spots'),
    );
    expect(stored, hasLength(1));

    LegacyBookCheckSession.forgetSpots(h.state);
    final back = await t.runAsync(update.storedSpots);
    expect(back!.lines, first.lines);
    expect(back.originals, first.originals);
    expect(back.steps, first.steps);
    expect(back.rules, first.rules);

    // 文件坏了：当没有，重新算出一样的结果。
    LegacyBookCheckSession.forgetSpots(h.state);
    await t.runAsync(() => stored.single.writeAsBytes([1, 2, 3]));
    expect(await t.runAsync(update.storedSpots), isNull);
    final again = await t.runAsync(update.spots);
    expect(again!.lines, first.lines);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  test('位置文件读写一致，长度不对时不用', () {
    final spots = CheckSpots(
      Int32List.fromList([3, 9, 200000]),
      Int32List.fromList([3, -1, 199999]),
      Int32List.fromList([0, -1, 1]),
      Int32List.fromList([0, 0, 7]),
      const ['甲', 'trim_trailing_spaces'],
    );
    final bytes = encodeCheckSpots(spots);
    final back = decodeCheckSpots(bytes)!;
    expect(back.lines, spots.lines);
    expect(back.originals, spots.originals);
    expect(back.steps, spots.steps);
    expect(back.rows, spots.rows);
    expect(back.rules, spots.rules);
    expect(back.pageLineAt(1), 9);
    expect(decodeCheckSpots(bytes.sublist(0, bytes.length - 4)), isNull);
    final empty = decodeCheckSpots(encodeCheckSpots(CheckSpots.empty))!;
    expect(empty.length, 0);
  });

  test('缓存清理：留下的报告用到的位置文件才留', () async {
    final dir = await Directory.systemTemp.createTemp('check-spots-cache-');
    addTearDown(() => dir.delete(recursive: true));
    final report = File('${dir.path}/${checkReportFileName('g1')}')
      ..writeAsStringSync(
        jsonEncode({
          'book_id': 'b',
          'guards': {'cleanup': 'c1'},
        }),
      );
    final used = File('${dir.path}/${checkSpotsFileName('c1')}')
      ..writeAsBytesSync([1, 2, 3, 4]);
    final orphan = File('${dir.path}/${checkSpotsFileName('old')}')
      ..writeAsBytesSync([1, 2, 3, 4, 5]);
    final preview = await previewCheckReportCleanup(dir, {'b': 'g1'});
    expect(preview.total, 3);
    expect(preview.kept, 2);
    expect(preview.files.map((f) => File(f.path).uri.pathSegments.last), [
      orphan.uri.pathSegments.last,
    ]);
    final done = await cleanCheckReports(dir, preview, {'b': 'g1'});
    expect(done.deleted, 1);
    expect(report.existsSync() && used.existsSync(), true);
    expect(orphan.existsSync(), false);
  });

  test('规则标识不看键的先后', () {
    expect(
      cleanupPipelineKey([
        {'kind': 'a', 'enabled': true},
      ]),
      cleanupPipelineKey([
        {'enabled': true, 'kind': 'a'},
      ]),
    );
  });

  test('进度：做完的不算进还没处理的，总数不倒退', () {
    const track = CheckTrack('chapters', '章节', 10, 3);
    expect(track.done, 7);
    expect(const CheckTrack('metadata', '信息', 2, 5).done, 0);
  });

  test('旧报告没有各项版本时读得出来', () {
    final report = BookCheckReport.fromJson({
      'guard': 'g',
      'evidence': '',
      'safe': 0,
      'checked_at': '2026-11-06T00:00:00',
      'domains': const [],
    });
    expect(report.guards, isEmpty);
    expect(report.baseline, isEmpty);
    final back = BookCheckReport.fromJson(
      BookCheckReport(
        'g',
        const [],
        null,
        '',
        0,
        guards: const {'chapters': 'a'},
        baseline: const {'chapters': 3},
      ).toJson(),
    );
    expect(back.guards['chapters'], 'a');
    expect(back.baseline['chapters'], 3);
  });
}
