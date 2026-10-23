import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/plugins/booksource_page.dart';

import 'desk_v86_plugins_test.dart' as v86;

class V88Api extends v86.FakeApi {
  V88Api() {
    sourceList[0]['file'] = '甲.json';
    sourceList[1]['file'] = '乙.json';
    sourceList[0]['groups'] = ['小说'];
    sourceList[1]['groups'] = [];
  }
  final requests = <(String, Map<String, dynamic>)>[];
  Completer<Map>? search;
  String? searchId;
  final queue = <Map<String, dynamic>>[];
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    requests.add((method, params));
    switch (method) {
      case 'search':
        searchId = '${params['searchId']}';
        search = Completer<Map>();
        return search!.future;
      case 'search.cancel':
        search!.complete({
          'searched': 1,
          'failed': 0,
          'cancelled': true,
          'skipped': 3,
        });
        return null;
      case 'sources.ping':
        events_.add({
          'event': 'ping.result',
          'id': 'https://a',
          'ok': true,
          'ms': 900,
          'health': {
            'ms': [1100, 900],
            'lastOk': 1,
            'failStreak': 0,
            'lastError': '',
          },
        });
        sourceList[0]['ping'] = {'ok': true, 'ms': 900};
        return {'total': 2, 'ok': 1};
      case 'sources.setEnabledMany':
        for (final s in sourceList) {
          if ((params['ids'] as List).contains(s['id'])) {
            s['enabled'] = params['enabled'];
          }
        }
        return null;
      case 'queue.add':
        queue.add({
          'id': 't1',
          'title': '测试书',
          'sourceName': '甲源',
          'status': 'running',
          'progress': {
            'done': 1,
            'total': 10,
            'speed': 2.5,
            'eta': 4,
            'concurrency': 3,
            'retrying': 1,
            'throttled': true,
          },
        });
        return {'taskId': 't1'};
      case 'queue.list':
        return {'tasks': queue, 'maxBooks': 2};
      case 'queue.pause':
        queue[0]['status'] = 'paused';
        return null;
      case 'queue.resume':
        queue[0]['status'] = 'running';
        return null;
      case 'queue.configure':
        return null;
      case 'library.rebuild':
        return {
          'path': 'copy.txt',
          'backup': 'copy.bak.txt',
          'quality': {'duplicateHeadings': 0},
        };
    }
    return super.call(method, params);
  }
}

/// V93：书源页的批量、维护等操作收进菜单，先打开菜单再点菜单项。
Future<void> menu(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> open(WidgetTester tester, V88Api api, Directory temp) async {
  tester.view.physicalSize = const Size(1500, 1050);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(api.events_.close);
  await tester.pumpWidget(
    MaterialApp(
      theme: deskTheme(),
      home: Scaffold(
        body: BookSourcePage(
          openApi: () async => api,
          settingsPath: '${temp.path}/ui.json',
          chooseFolder: () async => temp.path,
          chooseSourceFile: () async => null,
          importToLibrary: (_) async => null,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('小说搜索突发结果合并、停止排空尾批并保留已选书', (tester) async {
    final temp = Directory.systemTemp.createTempSync('novel-search-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V88Api();
    await open(tester, api, temp);
    await tester.enterText(
      find.byKey(const ValueKey('booksource-query')),
      '测试',
    );
    await tester.tap(find.byKey(const ValueKey('booksource-search')));
    await tester.pump();
    Map<String, dynamic> event(
      String source,
      List<Map<String, dynamic>> books,
      int ms,
    ) => {
      'event': 'search.result',
      'searchId': api.searchId,
      'sourceId': source,
      'sourceName': source,
      'ms': ms,
      'items': books,
    };
    api.events_.add(
      event('https://a', [
        {'name': '测试书', 'author': '作者甲', 'bookUrl': 'https://a/b'},
      ], 800),
    );
    await tester.pump();
    expect(find.text('测试书'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('booksource-select-0')));
    for (var i = 0; i < 20; i++) {
      api.events_.add(
        event('https://b$i', [
          for (var j = 0; j < 50; j++)
            {'name': '测试合并$j', 'author': '作者乙', 'bookUrl': 'https://b$i/$j'},
        ], 10),
      );
    }
    api.events_.add({
      'event': 'search.progress',
      'searchId': api.searchId,
      'done': 21,
      'total': 30,
      'skipped': 0,
    });
    await tester.pump(); // 不推进 50ms 定时器，直接停止也必须保留尾批。
    await tester.tap(find.byKey(const ValueKey('booksource-search-stop')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('找到 51 本'), findsOneWidget);
    expect(find.textContaining('已停止'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('已停止'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('booksource-download-selected')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final added = api.requests.where((r) => r.$1 == 'queue.add').toList();
    expect(added, hasLength(1));
    expect((added.single.$2['book'] as Map)['name'], '测试书');
  });

  testWidgets('V88 来源收起持久化、多选启停、流式测速徽标', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v88-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V88Api();
    await open(tester, api, temp);
    await tester.tap(find.text('书源 1/2'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('甲源'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('booksource-collapse-甲.json')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('甲源'), findsNothing);
    expect(
      jsonDecode(File('${temp.path}/ui.json').readAsStringSync())['collapsed'],
      contains('file:甲.json'),
    );
    await tester.tap(find.byKey(const ValueKey('booksource-collapse-甲.json')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('booksource-select-all')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('booksource-disable-selected')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.sourceList.every((s) => s['enabled'] == false), isTrue);
    expect(
      api.requests.lastWhere((r) => r.$1 == 'sources.setEnabledMany').$2['ids'],
      hasLength(2),
    );
    await menu(tester, 'booksource-menu-check');
    await tester.tap(find.byKey(const ValueKey('booksource-ping')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('可连接 900ms'), findsOneWidget);
    expect(find.text('可用 900ms'), findsNothing);
  });

  testWidgets('V88 首个搜索结果不等汇总、停止搜索、批量入队、暂停继续', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v88-stream-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V88Api();
    await open(tester, api, temp);
    await tester.enterText(
      find.byKey(const ValueKey('booksource-query')),
      '测试书',
    );
    await tester.tap(find.byKey(const ValueKey('booksource-search')));
    await tester.pump(const Duration(milliseconds: 100));
    api.events_.add({
      'event': 'search.result',
      'searchId': api.searchId,
      'sourceId': 'https://a',
      'sourceName': '甲源',
      'ms': 800,
      'items': [
        {'name': '测试书', 'author': '作者甲', 'bookUrl': 'https://a/b'},
      ],
    });
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byWidgetPredicate((w) => w is Text && w.data == '测试书'),
      findsOneWidget,
    );
    expect(api.search!.isCompleted, isFalse);
    await tester.tap(find.byKey(const ValueKey('booksource-search-stop')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('已停止'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('booksource-select-0')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(
      find.byKey(const ValueKey('booksource-download-selected')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('2.50 章/秒'), findsOneWidget);
    expect(find.textContaining('限流中'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('booksource-pause-t1')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('已暂停'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('booksource-resume-t1')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('booksource-pause-t1')), findsOneWidget);
  });

  testWidgets('V88 书架离线重新整理调用与备份反馈', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v88-rebuild-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V88Api();
    await open(tester, api, temp);
    await tester.tap(find.text('书架'));
    await tester.pump(const Duration(milliseconds: 300));
    await menu(tester, 'booksource-shelf-menu-k1');
    await tester.tap(find.byKey(const ValueKey('booksource-rebuild-k1')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      api.requests.any((r) => r.$1 == 'library.rebuild' && r.$2['key'] == 'k1'),
      isTrue,
    );
    expect(find.textContaining('copy.bak.txt'), findsOneWidget);
  });
}
