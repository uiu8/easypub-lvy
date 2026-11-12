// 检查页“成片出现”的原因：列表最前一行一个原因，默认收起；点行看说明，点箭头展开名下的问题。
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/checks/cause_copy.dart';
import 'package:easypub_desktop/desk/checks/issue_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChapterIssue issue(String id, String category, int line, {String? cause}) =>
    ChapterIssue(
      id,
      category,
      '$category 第 $line 行',
      '',
      [line],
      null,
      false,
      false,
      cause: cause,
    );

void main() {
  const twin = ChapterIssueCause(
    kind: 'twin',
    count: 3,
    total: 5,
    open: 5,
    near: 2,
    runs: 1,
    linked: {'number-gap': 1, 'number-reset': 1},
    category: 'duplicate-content',
  );

  testWidgets('原因排在最前、默认收起，展开后才列出名下的问题', (t) async {
    final page = ChapterIssuePage(
      [
        for (var i = 0; i < 3; i++)
          issue(
            'duplicate-content:$i',
            'duplicate-content',
            10 + i,
            cause: 'twin',
          ),
        issue('number-gap:a', 'number-gap', 20, cause: 'twin'),
        issue('number-reset:a', 'number-reset', 21, cause: 'twin'),
        issue('number-gap:b', 'number-gap', 90),
      ],
      6,
      0,
      effective: true,
      causes: const [twin],
      plainCategoryCounts: const {'number-gap': 1},
      filteredCategoryCounts: const {
        'duplicate-content': 3,
        'number-gap': 2,
        'number-reset': 1,
      },
    );
    ChapterIssueCause? opened;
    ChapterIssue? picked;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 340,
            height: 600,
            child: IssueResultList(
              initial: page,
              read: (_) async => page,
              onSelect: (_, issue) => picked = issue,
              onCause: (c) => opened = c,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    // 一行原因，写明数量和带出的问题；名下 5 条先不列，其余 1 条照常列出。
    expect(find.text('同一章存了两遍'), findsOneWidget);
    expect(find.text('3 章'), findsOneWidget);
    expect(find.textContaining('带出 2 处跳号'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('check-issue-duplicate-content:0')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('check-issue-number-gap:a')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('check-issue-number-gap:b')),
      findsOneWidget,
    );

    await t.tap(find.text('同一章存了两遍'));
    expect(opened?.kind, 'twin');
    expect(opened?.focus, 'cause:twin:');

    await t.tap(find.byTooltip('展开这 5 条'));
    await t.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('check-issue-duplicate-content:0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('check-issue-number-gap:a')),
      findsOneWidget,
    );
    await t.tap(find.byKey(const ValueKey('check-issue-number-gap:a')));
    expect(picked?.id, 'number-gap:a');
  });

  test('原因的说明写清数量、成因和处理后的结果', () {
    final body = causeBody(twin);
    expect(body, contains('3 章各存了两份'));
    expect(body, contains('1 章两份逐字相同'));
    expect(body, contains('2 章只差几行'));
    expect(body, contains('2 处跳号'));
    expect(causeAction(twin), '预览并排除多出来的一份…');
    const prefix = ChapterIssueCause(
      kind: 'no-prefix',
      count: 123,
      total: 123,
      open: 123,
      category: 'missing-heading-prefix',
    );
    expect(causeCount(prefix), '123 处');
    expect(causeBody(prefix), contains('不再提示'));
  });
}
