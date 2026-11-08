// R1c 书源界面重做（用户确认的预览）：左侧竖排导航与健康概况；书源页“文件 → 分组”树、
// 两级分节、检查面板；搜索页最近搜索与结果卡片；下载卡片的进度环、速度曲线、来源分布条。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desk_v88_booksource_test.dart' as v88;

void main() {
  v88.V88Api api0() {
    final api = v88.V88Api();
    for (var i = 0; i < 6; i++) {
      api.sourceList.add({
        'id': 'https://g$i.invalid',
        'name': '分组源$i',
        'groups': i < 4 ? [i.isEven ? '学习' : '精品'] : <String>[],
        'file': 'yckceo.json',
        'enabled': true,
        'supported': true,
        'reasons': [],
        'webView': false,
        'check': {
          'ok': i != 3,
          'ms': 400 + i * 100,
          'error': i == 3 ? '超时' : null,
        },
        'health': {
          'ms': [500, 700, 400 + i * 10],
        },
      });
    }
    return api;
  }

  testWidgets('书源页：文件下按分组分节，点树节点只看这一组，点书源在检查面板里看', (tester) async {
    final temp = Directory.systemTemp.createTempSync('r1c-sources-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = api0();
    await v88.open(tester, api, temp);
    // 左侧导航：健康概况（可用 = 校验通过的书源）。
    expect(find.text('可用 5'), findsOne);
    expect(find.text('未通过 1'), findsOne);
    await tester.tap(find.byKey(const ValueKey('booksource-tab-sources')));
    await tester.pump(const Duration(milliseconds: 300));
    // 两级分节：yckceo.json 下有“学习”“精品”“未分组”三节。
    for (final g in ['学习', '精品', '未分组']) {
      expect(
        find.byKey(ValueKey('booksource-subgroup-yckceo.json/$g')),
        findsOne,
        reason: g,
      );
    }
    // 收起一个分节，只收起这一节，并记住。
    await tester.tap(
      find.byKey(const ValueKey('booksource-collapse-yckceo.json/学习')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('分组源0'), findsNothing);
    expect(find.text('分组源1'), findsOne);
    expect(
      jsonDecode(File('${temp.path}/ui.json').readAsStringSync())['collapsed'],
      contains('file:yckceo.json/学习'),
    );
    await tester.tap(
      find.byKey(const ValueKey('booksource-collapse-yckceo.json/学习')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 树：展开文件，点“精品”，列表只剩精品的两个书源。
    await tester.tap(
      find.byKey(const ValueKey('booksource-tree-toggle-yckceo.json')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(
      find.byKey(const ValueKey('booksource-node-f:yckceo.json\ng:精品')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('分组源1'), findsOne);
    expect(find.text('分组源3'), findsOne);
    expect(find.text('分组源0'), findsNothing);
    expect(find.text('甲源'), findsNothing);
    // 点书源：右侧检查面板显示它，耗时曲线与“校验没通过”。
    await tester.tap(find.text('分组源3'));
    await tester.pump(const Duration(milliseconds: 200));
    final inspector = find.byKey(
      const ValueKey('booksource-inspector-https://g3.invalid'),
    );
    expect(inspector, findsOne);
    expect(
      find.descendant(
        of: inspector,
        matching: find.byKey(const ValueKey('booksource-inspector-spark')),
      ),
      findsOne,
    );
    expect(
      find.descendant(of: inspector, matching: find.text('校验没通过：超时')),
      findsOne,
    );
    // 面板里的“测速”只测这一个书源。
    await tester.tap(
      find.byKey(
        const ValueKey('booksource-inspector-ping-https://g3.invalid'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(api.requests.lastWhere((r) => r.$1 == 'sources.ping').$2['ids'], [
      'https://g3.invalid',
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('搜索页：最近搜索记住并可点着再搜；结果卡片没有封面时显示首字', (tester) async {
    final temp = Directory.systemTemp.createTempSync('r1c-search-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = api0();
    await v88.open(tester, api, temp);
    await tester.enterText(
      find.byKey(const ValueKey('booksource-query')),
      '诡秘之主',
    );
    await tester.tap(find.byKey(const ValueKey('booksource-search')));
    await tester.pump();
    api.events_.add({
      'event': 'search.result',
      'searchId': api.searchId,
      'sourceId': 'https://a',
      'sourceName': '甲源',
      'ms': 300,
      'items': [
        {
          'name': '诡秘之主',
          'author': '乌贼',
          'bookUrl': 'https://a/1',
          'chapterCount': 1432,
          'countExact': true,
        },
      ],
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('乌贼 · 1432 章'), findsOne);
    expect(find.text('1 个书源 · 最快 0.3s'), findsOne);
    expect(find.text('诡'), findsWidgets);
    api.search!.complete({'searched': 1, 'failed': 0});
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      jsonDecode(
        File('${temp.path}/ui.json').readAsStringSync(),
      )['recentSearches'],
      ['诡秘之主'],
    );
    await tester.pumpWidget(const SizedBox());
    // 重新打开：空搜索页列出最近搜索，点一下就再搜。
    final again = api0();
    await v88.open(tester, again, temp);
    expect(find.byKey(const ValueKey('booksource-recent-诡秘之主')), findsOne);
    await tester.tap(find.byKey(const ValueKey('booksource-recent-诡秘之主')));
    await tester.pump();
    expect(again.requests.where((r) => r.$1 == 'search'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('下载卡片：进度环、速度曲线、章节来源分布条', (tester) async {
    final temp = Directory.systemTemp.createTempSync('r1c-downloads-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = api0();
    api.queue.add({
      'id': 't9',
      'title': '诡秘之主',
      'sourceName': '甲源',
      'status': 'running',
      'progress': {'done': 0, 'total': 100},
    });
    await v88.open(tester, api, temp);
    await tester.tap(find.byKey(const ValueKey('booksource-tab-downloads')));
    await tester.pump(const Duration(milliseconds: 300));
    for (var i = 0; i < 6; i++) {
      api.events_.add({
        'event': 'download.progress',
        'taskId': 't9',
        'stage': 'chapters',
        'progress': {
          'done': 10 * (i + 1),
          'total': 100,
          'speed': 5 + i,
          'sourceCount': 2,
          'chapter': {
            'index': i,
            'status': 'completed',
            'source': i < 4 ? 'https://a' : 'https://b',
          },
        },
      });
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byKey(const ValueKey('booksource-task-ring-t9')), findsOne);
    expect(find.text('60%'), findsOne);
    expect(find.byKey(const ValueKey('booksource-task-spark-t9')), findsOne);
    final share = find.byKey(const ValueKey('booksource-task-share-t9'));
    expect(share, findsOne);
    expect(tester.getSize(share).height, 5);
    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(of: share, matching: find.byType(Tooltip)).first,
          )
          .message,
      '甲源：4 章\n乙源：2 章',
    );
    await tester.pumpWidget(const SizedBox());
  });
}
