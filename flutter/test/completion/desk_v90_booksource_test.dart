import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desk_v88_booksource_test.dart' as v88;
import 'desk_v89_booksource_test.dart' as v89;

class V90Api extends v89.V89Api {
  List<Map<String, dynamic>> pages = [
    {
      'sourceId': 'https://a',
      'sourceName': '甲源',
      'page': 1,
      'nextPage': 2,
      'ended': false,
      'failed': false,
    },
    {
      'sourceId': 'https://b',
      'sourceName': '乙源',
      'page': 0,
      'nextPage': 1,
      'ended': false,
      'failed': true,
      'cause': 'network',
    },
  ];
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (method == 'search.more' || method == 'search.retry') {
      requests.add((method, params));
      final retry = method == 'search.retry';
      final id = retry ? 'https://b' : 'https://a';
      events_.add({
        'event': 'search.result',
        'searchId': params['searchId'],
        'sourceId': id,
        'sourceName': id,
        'items': [
          {'name': retry ? '测试书' : '测试续页', 'author': '作者', 'bookUrl': '$id/b'},
        ],
        'ms': 1,
      });
      if (retry)
        pages[1]['failed'] = false;
      else {
        pages[0]['page'] = 2;
        pages[0]['nextPage'] = 3;
      }
      return {'searched': 1, 'failed': 0, 'pages': pages};
    }
    if (method == 'subscriptions.list')
      return [
        {
          'url': 'https://fixture.invalid/sources.json',
          'startup': false,
          'days': 0,
          'count': 2,
          'versions': [
            {'at': 1, 'count': 2},
          ],
          'hash': 'test',
        },
      ];
    if (method == 'subscriptions.preview') {
      requests.add((method, params));
      return {
        'preview': {
          'id': 'p1',
          'diff': {
            'added': [],
            'removed': [],
            'changed': [
              {
                'name': '甲源',
                'fields': ['ruleContent'],
              },
            ],
          },
        },
      };
    }
    if (method == 'subscriptions.apply') {
      requests.add((method, params));
      return {
        'reverted': [
          {'name': '甲源', 'cause': 'rule'},
        ],
      };
    }
    return super.call(method, params);
  }
}

void main() {
  testWidgets('V90 翻页与失败重试沿用搜索 ID，保持选择，丢弃旧消息', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v90-search-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V90Api();
    await v88.open(tester, api, temp);
    await tester.enterText(
      find.byKey(const ValueKey('booksource-query')),
      '测试',
    );
    await tester.tap(find.byKey(const ValueKey('booksource-search')));
    await tester.pump();
    final original = api.searchId;
    api.events_.add({
      'event': 'search.result',
      'searchId': original,
      'sourceId': 'https://a',
      'sourceName': '甲源',
      'items': [
        {'name': '测试书', 'author': '作者', 'bookUrl': 'https://a/b'},
      ],
      'ms': 1,
    });
    api.search!.complete({'searched': 2, 'failed': 1, 'pages': api.pages});
    await v89.pump(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-select-0')));
    await tester.tap(find.byKey(const ValueKey('booksource-search-more')));
    await v89.pump(tester);
    expect(find.text('测试续页'), findsOneWidget);
    expect(find.text('加入下载（1）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('booksource-search-retry')));
    await v89.pump(tester);
    expect(
      api.requests
          .where((r) => r.$1 == 'search.more' || r.$1 == 'search.retry')
          .every((r) => r.$2['searchId'] == original),
      true,
    );
    expect(find.text('加入下载（1）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('booksource-search')));
    await tester.pump();
    api.events_.add({
      'event': 'search.result',
      'searchId': original,
      'sourceId': 'https://a',
      'items': [
        {'name': '旧搜索污染', 'author': 'x'},
      ],
    });
    api.search!.complete({'searched': 0, 'failed': 0, 'pages': []});
    await v89.pump(tester);
    expect(find.text('旧搜索污染'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await v89.pump(tester);
  });

  testWidgets('V90 订阅检查只预览，明确应用才替换并提示自动回退', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v90-sub-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V90Api();
    await v88.open(tester, api, temp);
    await tester.tap(find.text('书源 1/2'));
    await v89.pump(tester);
    await v88.menu(tester, 'booksource-menu-import');
    await tester.tap(find.byKey(const ValueKey('booksource-subscriptions')));
    await v89.pump(tester);
    await tester.tap(find.text('检查更新'));
    await v89.pump(tester);
    expect(find.textContaining('ruleContent'), findsOneWidget);
    expect(api.requests.where((r) => r.$1 == 'subscriptions.apply'), isEmpty);
    await tester.tap(
      find.byKey(const ValueKey('booksource-subscription-apply')),
    );
    await v89.pump(tester);
    expect(
      api.requests.where((r) => r.$1 == 'subscriptions.apply'),
      hasLength(1),
    );
    await tester.tap(find.text('关闭').last);
    await v89.pump(tester);
    expect(find.textContaining('自动恢复旧版'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await v89.pump(tester);
  });
}
