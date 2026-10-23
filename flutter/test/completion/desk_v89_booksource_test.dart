import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/plugins/booksource_page.dart';

import 'desk_v88_booksource_test.dart' as v88;

class V89Api extends v88.V88Api {
  V89Api() {
    for (final (i, s) in sourceList.indexed) {
      s['file'] = '测试.json';
      s['customOrder'] = i;
      s['rating'] = 0;
      s['tags'] = i == 0 ? ['可用', '批量'] : ['慢'];
      s['recommended'] = i == 0;
    }
  }
  final presets = <Map<String, dynamic>>[];
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    switch (method) {
      case 'network.proxy.get':
      case 'network.proxy.refresh':
        return {'mode': 'none', 'scope': 'all', 'url': '', 'system': {}};
      case 'network.proxy.test':
        requests.add((method, params));
        return {
          'samples': [
            {'label': '直连', 'ok': false, 'error': '连接中断', 'ms': 10},
            {
              'label': '当前选择',
              'ok': true,
              'status': 200,
              'protocol': 'HTTP/2.0',
              'ms': 20,
              'route': {'reason': '系统代理', 'endpoint': 'http://127.0.0.1:7890/'},
            },
          ],
        };
      case 'network.proxy.set':
        requests.add((method, params));
        return null;
      case 'sources.pin':
        requests.add((method, params));
        for (final s in sourceList) {
          if ((params['ids'] as List).contains(s['id'])) {
            s['pinned'] =
                params['position'] != 'bottom' && params['pinned'] != false;
            s['customOrder'] = params['position'] == 'bottom' ? 10 : -1;
          }
        }
        return null;
      case 'sources.order':
        requests.add((method, params));
        for (final s in sourceList) {
          s['customOrder'] = (params['ids'] as List).indexOf(s['id']);
        }
        return null;
      case 'sources.detail':
        return {
          'crawl': {},
          'suggestion': {
            'concurrency': 5,
            'minInterval': 200,
            'maxInterval': 400,
          },
          'learned': {'safeLimit': 6},
          'health': {
            'ms': [20, 80],
          },
          'tags': ['批量'],
          'group': '小说',
          'header': '{}',
        };
      case 'sources.crawlProfile.set':
      case 'sources.rate':
        requests.add((method, params));
        return null;
      case 'filters.save':
        requests.add((method, params));
        presets.add(Map.from(params));
        return null;
      case 'filters.list':
        return presets;
      case 'search.enrich':
        requests.add((method, params));
        for (final r in params['results'] as List) {
          for (final s in r['sources'] as List) {
            events_.add({
              'event': 'search.enrich',
              'searchId': params['searchId'],
              'sourceId': s['sourceId'],
              'book': {
                ...s['book'] as Map,
                'chapterCount': s['sourceId'] == 'https://a' ? 100 : 200,
                'countExact': true,
              },
            });
          }
        }
        return {'items': []};
    }
    return super.call(method, params);
  }
}

Future<void> pump(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 350));

class CatalogueApi extends V89Api {
  final records = <Map<String, dynamic>>[
    {
      'key': 'changed',
      'book': {'name': '同章数样书', 'author': '自拟'},
      'sourceName': '甲源',
      'chapters': 120,
      'newChapters': 0,
      'catalogChanged': true,
      'catalogChanges': {'modified': 1, 'moved': 2},
    },
    {
      'key': 'error',
      'book': {'name': '未查完样书', 'author': '自拟'},
      'sourceName': '乙源',
      'chapters': 120,
      'newChapters': 0,
      'checkError': '需要登录',
    },
  ];
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (method == 'library.list') return records;
    if (method == 'library.check') {
      return {
        'records': records,
        'newChapters': 0,
        'changedBooks': 1,
        'errors': 1,
      };
    }
    if (method == 'library.update') {
      requests.add((method, params));
      return {'taskId': 'toc-update'};
    }
    return super.call(method, params);
  }
}

void main() {
  testWidgets('同章数变化可以全部追更，检查失败不显示最新，失败追更保留成品', (tester) async {
    final temp = Directory.systemTemp.createTempSync('catalogue-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = CatalogueApi();
    await v88.open(tester, api, temp);
    await tester.tap(find.text('书架'));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-shelf-check')));
    await pump(tester);
    expect(find.textContaining('1 修改 · 2 调序'), findsOneWidget);
    expect(find.textContaining('1 本检查失败'), findsOneWidget);
    expect(find.text('都是最新的。'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('booksource-shelf-update-all')));
    await pump(tester);
    expect(
      api.requests
          .where((r) => r.$1 == 'library.update')
          .map((r) => r.$2['key']),
      ['changed'],
    );
    final task = DownloadTask('t', '同章数样书', '甲源');
    task.applyResult({
      'outcome': {
        'path': 'old.txt',
        'outputPreserved': true,
        'chapters': 120,
        'downloaded': 119,
        'failures': [
          {'index': 1, 'reason': '需要登录'},
        ],
      },
    });
    expect(task.status, 'failed');
    expect(task.stage, contains('原 TXT 已保留'));
    expect(task.outputPreserved, true);
    await tester.pumpWidget(const SizedBox());
    await pump(tester);
  });
  testWidgets('网络草稿对照不保存，确认后才应用', (tester) async {
    final temp = Directory.systemTemp.createTempSync('network-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V89Api();
    await v88.open(tester, api, temp);
    await tester.tap(find.text('设置'));
    await pump(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('booksource-proxy')));
    await tester.tap(find.byKey(const ValueKey('booksource-proxy')));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('network-mode')));
    await pump(tester);
    await tester.tap(find.text('系统代理').last);
    await pump(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('network-test')));
    await tester.tap(find.byKey(const ValueKey('network-test')));
    await pump(tester);
    expect(api.requests.where((r) => r.$1 == 'network.proxy.set'), isEmpty);
    expect(
      api.requests
          .firstWhere((r) => r.$1 == 'network.proxy.test')
          .$2['config']['mode'],
      'system',
    );
    expect(find.textContaining('HTTP/2.0'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('network-save')));
    await pump(tester);
    expect(
      api.requests
          .firstWhere((r) => r.$1 == 'network.proxy.set')
          .$2['config']['scope'],
      'all',
    );
    await tester.pumpWidget(const SizedBox());
    await pump(tester);
  });
  testWidgets('V89 置顶置底、拖动、标签与推荐筛选、保存组合', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v89-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V89Api();
    await v88.open(tester, api, temp);
    await tester.tap(find.text('书源 1/2'));
    await pump(tester);
    await v88.menu(tester, 'booksource-row-menu-https://a');
    await tester.tap(find.byKey(const ValueKey('booksource-pin-https://a')));
    await pump(tester);
    expect(api.sourceList[0]['pinned'], true);
    await v88.menu(tester, 'booksource-row-menu-https://a');
    await tester.tap(find.byKey(const ValueKey('booksource-bottom-https://a')));
    await pump(tester);
    expect(api.sourceList[0]['pinned'], false);
    final first = find.byKey(
      const ValueKey('booksource-drag-https://a-测试.json'),
    );
    final second = find.byKey(
      const ValueKey('booksource-drag-https://b-测试.json'),
    );
    await tester.dragFrom(
      tester.getCenter(first),
      tester.getCenter(second) - tester.getCenter(first) + const Offset(0, 4),
    );
    await pump(tester);
    expect(api.requests.any((r) => r.$1 == 'sources.order'), true);
    await tester.tap(find.byKey(const ValueKey('booksource-filters-toggle')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('booksource-recommended')));
    await pump(tester);
    expect(find.text('乙源'), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, '批量'));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-filter-save')));
    await pump(tester);
    await tester.enterText(find.byType(TextField).last, '常用批量');
    await tester.tap(find.text('确定'));
    await pump(tester);
    expect(api.presets.single['filter']['tags'], ['批量']);
    expect(api.presets.single['filter']['recommended'], true);
    await tester.pumpWidget(const SizedBox());
    await pump(tester);
  });
  testWidgets('V89 参数建议需应用再保存，评分跟随保存', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v89-profile-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V89Api();
    await v88.open(tester, api, temp);
    await tester.tap(find.text('书源 1/2'));
    await pump(tester);
    await tester.tap(find.text('甲源'));
    await pump(tester);
    // R1c 起宽窗口下点书源在右侧检查面板里看，详情从面板里打开。
    await tester.tap(
      find.byKey(const ValueKey('booksource-inspector-detail-https://a')),
    );
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-profile')));
    await pump(tester);
    expect(
      api.requests.where((r) => r.$1 == 'sources.crawlProfile.set'),
      isEmpty,
    );
    await tester.tap(find.text('应用导入建议'));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-rating')));
    await pump(tester);
    await tester.tap(find.text('评分 2').last);
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-profile-save')));
    await pump(tester);
    final p = api.requests
        .firstWhere((r) => r.$1 == 'sources.crawlProfile.set')
        .$2;
    expect(p['profile']['concurrency'], 5);
    expect(p['profile']['minInterval'], 200);
    expect(
      api.requests.firstWhere((r) => r.$1 == 'sources.rate').$2['rating'],
      2,
    );
    await tester.pumpWidget(const SizedBox());
    await pump(tester);
  });
  testWidgets('V89 优先搜索参数、目录补全、章数与不全标记', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v89-sort-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V89Api();
    await v88.open(tester, api, temp);
    await tester.tap(find.byKey(const ValueKey('booksource-priority-only')));
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('booksource-query')),
      '样书',
    );
    await tester.tap(find.byKey(const ValueKey('booksource-search')));
    await pump(tester);
    expect(
      api.requests.firstWhere((r) => r.$1 == 'search').$2['onlyPriority'],
      true,
    );
    for (final id in ['a', 'b']) {
      api.events_.add({
        'event': 'search.result',
        'searchId': api.searchId,
        'sourceId': 'https://$id',
        'sourceName': id == 'a' ? '甲源' : '乙源',
        'ms': 20,
        'items': [
          {'name': '样书', 'author': '甲', 'bookUrl': 'https://$id/book'},
        ],
      });
    }
    api.search!.complete({'searched': 2, 'failed': 0});
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-enrich')));
    await pump(tester);
    expect(find.textContaining('200 章'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('booksource-result-0')));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-source-choice')));
    await pump(tester);
    expect(find.textContaining('可能不全'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await pump(tester);
  });
}
