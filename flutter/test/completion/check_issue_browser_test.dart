import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/checks/issue_browser.dart';
import 'package:easypub_desktop/desk/checks/check_view_state.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class Issues extends Fake
    implements ChapterSession, ChapterIssueContextSession {
  final offsets = <int>[];
  final modes = <bool>[];
  final pending = <String, Completer<String>>{};
  bool delayed = false;
  int total = 51;
  @override
  Future<ChapterPage> read(
    int offset, {
    bool includeBody = false,
    String? preferredNodeId,
  }) async => const ChapterPage([], 0, 0, 'guard');
  @override
  Future<ChapterIssuePage> issues(
    ChapterPage page,
    int offset, {
    bool effective = false,
  }) async {
    offsets.add(offset);
    modes.add(effective);
    return ChapterIssuePage(
      List.generate(
        (total - offset).clamp(0, 50),
        (i) => ChapterIssue(
          '${offset + i}',
          'number',
          '问题 ${offset + i}',
          '编号需要核对',
          [offset + i + 1],
          null,
          false,
          false,
        ),
      ),
      total,
      offset,
      effective: effective,
    );
  }

  @override
  Future<String> issueSource(ChapterIssuePage page, ChapterIssue issue) async {
    if (delayed) return (pending[issue.id] = Completer<String>()).future;
    return '${page.effective ? '有效' : '原始'}上下文 ${issue.id}';
  }

  @override
  Future<ChapterIssueContext> issueContext(
    ChapterIssuePage page,
    ChapterIssue issue, {
    int anchor = 0,
  }) async => ChapterIssueContext(
    effectiveText: await issueSource(page, issue),
    originalText: '原始上下文 ${issue.id}',
  );
}

class ContextIssues extends Issues implements ChapterIssueContextSession {
  @override
  Future<ChapterIssueContext> issueContext(
    ChapterIssuePage page,
    ChapterIssue issue, {
    int anchor = 0,
  }) async => ChapterIssueContext(
    effectiveText: '有效上下文 ${issue.id}',
    originalText: '原始上下文 ${issue.id}',
  );
}

class PairedIssues extends ContextIssues {
  @override
  Future<ChapterIssuePage> issues(
    ChapterPage page,
    int offset, {
    bool effective = false,
  }) async => const ChapterIssuePage(
    [
      ChapterIssue(
        'gap',
        'number-gap',
        '第12章后到了第14章',
        '核对是否漏识别标题。',
        [120, 140],
        null,
        false,
        false,
        anchors: [
          ChapterIssueAnchor('第12章', 120, 'a', 0, 90, 120),
          ChapterIssueAnchor('第14章', 140, 'b', 0, 0, 140),
        ],
      ),
    ],
    1,
    0,
    effective: true,
  );
  @override
  Future<ChapterIssueContext> issueContext(
    ChapterIssuePage page,
    ChapterIssue issue, {
    int anchor = 0,
  }) async => ChapterIssueContext(
    rows: [
      ChapterContextRow(
        anchor == 0 ? '前章末尾的证据正文' : '后章开头的证据正文',
        line: anchor == 0 ? 120 : 140,
        originalLine: anchor == 0 ? 120 : 140,
      ),
    ],
    originalRows: [
      const ChapterContextRow('导入原文的对应段落', line: 120, originalLine: 120),
    ],
  );
}

void main() {
  testWidgets(
    'number gap shows the two evidence bodies side by side and traces one location',
    (t) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: CheckIssueBrowser(
              session: PairedIssues(),
              enabled: true,
              onChapter: (_) {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final first = t.getRect(find.text('前章末尾的证据正文'));
      final second = t.getRect(find.text('后章开头的证据正文'));
      expect(first.left, lessThan(second.left));
      expect(first.top, closeTo(second.top, 1));
      expect(find.text('显示问题位置及附近内容。'), findsNothing);
      await t.tap(find.byTooltip('对照方式'));
      await t.pumpAndSettle();
      await t.tap(find.text('追溯原稿').last);
      await t.pumpAndSettle();
      expect(find.text('导入原文的对应段落'), findsOneWidget);
      expect(find.text('前章末尾的证据正文'), findsOneWidget);
      expect(find.text('后章开头的证据正文'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow context browser returns to list and navigates adjacent issues',
    (tester) async {
      tester.view.physicalSize = const Size(480, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = ContextIssues()..total = 4;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: CheckIssueBrowser(
              session: session,
              enabled: true,
              onChapter: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('有效上下文 0'), findsOneWidget);
      await tester.tap(find.byTooltip('下一个问题'));
      await tester.pumpAndSettle();
      expect(find.text('有效上下文 1'), findsOneWidget);
      await tester.tap(find.byTooltip('返回问题列表'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('check-issue-list')), findsOneWidget);
      expect(find.text('有效上下文 1'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('check-issue-2')));
      await tester.pumpAndSettle();
      expect(find.text('有效上下文 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'all issue pages, direct context, source mode and stale-result guard',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = Issues();
      ChapterIssue? located;
      Widget app(bool enabled) => MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: CheckIssueBrowser(
            session: session,
            enabled: enabled,
            onChapter: (i) => located = i,
            onRepair: (_) {},
          ),
        ),
      );
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(find.text('有效上下文 0'), findsOneWidget);
      final slider = find.byKey(const ValueKey('issue-position'));
      await tester.drag(slider, const Offset(1500, 0));
      await tester.pumpAndSettle();
      expect(session.offsets, containsAllInOrder([0, 50]));
      expect(find.text('有效上下文 50'), findsOneWidget);
      await tester.tap(find.text('定位章节'));
      expect(located!.id, '50');
      await tester.tap(find.byTooltip('对照方式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('追溯原稿').last);
      await tester.pumpAndSettle();
      expect(session.modes.every((mode) => mode), isTrue);
      expect(find.text('原始上下文 50'), findsOneWidget);
      expect(find.text('有效上下文 50'), findsOneWidget);
      await tester.drag(slider, const Offset(-1500, 0));
      await tester.pumpAndSettle();
      session.delayed = true;
      await tester.tap(find.byKey(const ValueKey('check-issue-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('check-issue-2')));
      await tester.pump();
      session.pending['2']!.complete('正确的第二项上下文');
      await tester.pump();
      session.pending['1']!.complete('过期第一项');
      await tester.pumpAndSettle();
      expect(find.text('正确的第二项上下文'), findsOneWidget);
      expect(find.text('过期第一项'), findsNothing);
      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(find.text('重新检查后显示当前问题'), findsOneWidget);
      expect(find.text('定位章节'), findsNothing);
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(480, 800);
      session.delayed = false;
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(find.text('有效上下文 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('rechecking keeps selection and clamps a repaired final page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = Issues();
    final view = IssueViewState();
    Widget app(int revision) => MaterialApp(
      theme: deskTheme(),
      home: Scaffold(
        body: CheckIssueBrowser(
          viewState: view,
          session: session,
          enabled: true,
          revision: revision,
          onChapter: (_) {},
        ),
      ),
    );
    await tester.pumpWidget(app(0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('check-issue-2')));
    await tester.pumpAndSettle();
    // V15：问题列表停靠在窄列时“重新检查”只留图标。
    await tester.tap(find.byTooltip('重新检查'));
    await tester.pumpAndSettle();
    expect(find.text('有效上下文 2'), findsOneWidget);
    await tester.pumpWidget(app(1));
    await tester.pumpAndSettle();
    expect(find.text('有效上下文 2'), findsOneWidget);
    final slider = find.byKey(const ValueKey('issue-position'));
    await tester.drag(slider, const Offset(1500, 0));
    await tester.pumpAndSettle();
    expect(find.text('有效上下文 50'), findsOneWidget);
    // Leaving the page destroys the browser; returning must reread its place.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(1));
    await tester.pumpAndSettle();
    expect(view.offset, 50);
    expect(find.text('有效上下文 50'), findsOneWidget);
    session.total = 50;
    await tester.pumpWidget(app(2));
    await tester.pumpAndSettle();
    expect(session.offsets.sublist(session.offsets.length - 2), [50, 0]);
    expect(find.text('问题 1 / 50'), findsOneWidget);
    expect(find.text('有效上下文 0'), findsOneWidget);
    session.total = 0;
    await tester.pumpWidget(app(3));
    await tester.pumpAndSettle();
    expect(find.text('有效上下文 0'), findsNothing);
    expect(find.text('定位章节'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
