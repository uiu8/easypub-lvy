// V86 插件系统与书源下载页面。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easypub_desktop/application/plugin_host.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/plugins/booksource_page.dart';
import 'package:easypub_desktop/desk/plugins/plugins_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 由 tools/test_flutter.ps1 构建（release）。
File pluginExe() {
  final exe = File('../target/release/easypub_plugin_booksource.exe');
  if (!exe.existsSync()) {
    fail(
      '缺少插件程序：先运行 cargo build -p easypub_booksource --bin easypub_plugin_booksource --release',
    );
  }
  return exe;
}

Directory makePlugin(Directory root, {String? sha}) {
  final dir = Directory('${root.path}/booksource')..createSync(recursive: true);
  final exe = pluginExe().copySync('${dir.path}/easypub_plugin_booksource.exe');
  File('${dir.path}/plugin.json').writeAsStringSync(
    jsonEncode({
      'id': 'booksource',
      'name': '书源下载',
      'version': '0.1.0',
      'description': '测试',
      'executable': 'easypub_plugin_booksource.exe',
      'sha256': sha ?? sha256.convert(exe.readAsBytesSync()).toString(),
      'permissions': ['network', 'write-downloads'],
    }),
  );
  return dir;
}

class FakeApi implements BookSourceApi {
  final events_ = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <String>[];
  final List<Map<String, dynamic>> sourceList = [
    {
      'id': 'https://a',
      'name': '甲源',
      'group': '小说',
      'enabled': true,
      'supported': true,
      'reasons': [],
      'webView': false,
    },
    {
      'id': 'https://b',
      'name': '乙源',
      'group': '',
      'enabled': false,
      'supported': false,
      'reasons': ['漫画书源，暂只支持文字书源'],
      'webView': false,
    },
  ];
  Map<String, dynamic>? downloadParams;
  @override
  Stream<Map<String, dynamic>> get events => events_.stream;
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add(method);
    switch (method) {
      case 'sources.list':
        return sourceList;
      case 'search':
        events_.add({
          'event': 'search.progress',
          'done': 1,
          'total': 1,
          'found': 1,
        });
        return {
          'searched': 1,
          'failed': 0,
          'results': [
            {
              'name': '剑来',
              'author': '烽火',
              'sources': [
                {
                  'sourceId': 'https://a',
                  'sourceName': '甲源',
                  'book': {
                    'name': '剑来',
                    'author': '烽火',
                    'bookUrl': 'https://a/1',
                    'intro': '简介',
                  },
                },
                {
                  'sourceId': 'https://c',
                  'sourceName': '丙源',
                  'book': {
                    'name': '剑来',
                    'author': '烽火',
                    'bookUrl': 'https://c/9',
                  },
                },
              ],
            },
          ],
        };
      case 'book.info':
        return {
          ...params['book'] as Map,
          'tocUrl': 'https://a/toc',
          'kind': '仙侠',
        };
      case 'book.toc':
        return [
          {'index': 0, 'title': '第一章', 'url': 'https://a/c1'},
          {'index': 1, 'title': '第二章', 'url': 'https://a/c2', 'isVip': true},
        ];
      case 'download.start':
        downloadParams = params;
        return {'taskId': 't1'};
      case 'sources.check':
        sourceList[0]['check'] = {'ok': false, 'ms': 900, 'error': '超时'};
        return {'total': 1, 'ok': 0};
      case 'sources.setEnabled':
        for (final s in sourceList) {
          if ((params['ids'] as List).contains(s['id'])) {
            s['enabled'] = params['enabled'];
          }
        }
        return null;
      case 'library.list':
        return [
          {
            'key': 'k1',
            'sourceId': 'https://a',
            'sourceName': '甲源',
            'book': {'name': '剑来', 'author': '烽火'},
            'chapters': 100,
            'newChapters': 2,
            'latestOnline': '第一百零二章',
            'path': 'D:/下载/剑来 - 烽火.txt',
          },
        ];
      case 'library.update':
        return {'taskId': 't9'};
    }
    return null;
  }
}

/// V93：书源页的检查、维护操作收进菜单，先打开菜单再点菜单项。
Future<void> _menu(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  test(
    'plugin registry verifies, enables and talks to the real plugin process',
    () async {
      final tmp = await Directory.systemTemp.createTemp('ep-plugin-');
      addTearDown(() => tmp.delete(recursive: true));
      final bundled = Directory('${tmp.path}/bundled');
      makePlugin(bundled);
      final registry = PluginRegistry(
        roots: [bundled.path],
        userRoot: '${tmp.path}/user',
        dataRoot: '${tmp.path}/data',
      );
      final entry = registry.scan().single;
      expect(entry.problem, isNull);
      expect(entry.enabled, isFalse, reason: '新插件默认停用');
      expect(entry.removable, isFalse);
      await expectLater(
        registry.client('booksource'),
        throwsA(isA<PluginError>()),
      );
      await registry.setEnabled('booksource', true);
      final client = await registry.client('booksource');
      final hello = await client.call('hello') as Map;
      expect(hello['protocol'], 1);
      final sources = File('${tmp.path}/sources.json')
        ..writeAsStringSync(
          jsonEncode([
            {
              'bookSourceUrl': 'https://example.invalid',
              'bookSourceName': '测试源',
              'searchUrl': '/s?q={{key}}',
              'header': '{"Cookie":"secret=1","User-Agent":"x"}',
              'ruleSearch': {
                'bookList': 'li',
                'name': 'a@text',
                'bookUrl': 'a@href',
              },
              'ruleContent': {'content': '#c@text'},
            },
            {
              'bookSourceUrl': 'https://comic.invalid',
              'bookSourceName': '漫画',
              'bookSourceType': 2,
              'searchUrl': '/s',
            },
          ]),
        );
      final imported =
          await client.call('sources.import', {'path': sources.path}) as Map;
      expect(imported['added'], 2);
      final list = (await client.call('sources.list') as List).cast<Map>();
      expect(list.firstWhere((s) => s['name'] == '测试源')['supported'], isTrue);
      expect(
        list.firstWhere((s) => s['name'] == '测试源')['reasons'].join(),
        contains('Cookie 已去掉'),
      );
      expect(list.firstWhere((s) => s['name'] == '漫画')['enabled'], isFalse);
      final stored = File(
        '${registry.dataDirectory('booksource')}/sources.json',
      ).readAsStringSync();
      expect(stored, isNot(contains('secret=1')), reason: '书源自带的 Cookie 不保存');
      await expectLater(client.call('nope'), throwsA(isA<PluginError>()));
      await registry.closeAll();

      // 校验值不符时阻止运行；从文件夹安装到用户目录后可卸载。
      final bad = Directory('${tmp.path}/bad');
      makePlugin(bad, sha: '0' * 64);
      final r2 = PluginRegistry(
        roots: [bad.path],
        userRoot: '${tmp.path}/user2',
        dataRoot: '${tmp.path}/data2',
      );
      expect(r2.scan().single.problem, contains('校验值不符'));
      await expectLater(
        r2.installFromFolder('${bad.path}/booksource'),
        throwsA(isA<PluginError>()),
      );
      final installed = await r2.installFromFolder(
        '${bundled.path}/booksource',
      );
      expect(
        installed.removable,
        isTrue,
        reason: '装进用户目录的插件可卸载（同标识时优先用用户目录里的）',
      );
      await r2.uninstall('booksource');
      expect(Directory('${tmp.path}/user2/booksource').existsSync(), isFalse);
    },
  );

  testWidgets(
    'book source page: search, choose source, read toc, download, add to library',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeApi();
      final imported = <String>[];
      final settings =
          '${Directory.systemTemp.path}/ep-bs-ui-${DateTime.now().microsecondsSinceEpoch}.json';
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: BookSourcePage(
              openApi: () async => api,
              settingsPath: settings,
              chooseFolder: () async => 'D:/下载',
              chooseSourceFile: () async => null,
              importToLibrary: (path) async {
                imported.add(path);
                return null;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('书源 1/2'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('booksource-query')),
        '剑来',
      );
      await tester.tap(find.byKey(const ValueKey('booksource-search')));
      await tester.pumpAndSettle();
      expect(find.textContaining('找到 1 本'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('booksource-result-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('booksource-load-toc')));
      await tester.pumpAndSettle();
      expect(find.textContaining('共 2 章'), findsOneWidget);
      expect(find.textContaining('含付费章节'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('booksource-to')), '1');
      await tester.tap(find.byKey(const ValueKey('booksource-download')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        api.downloadParams!['options']['folder'],
        'D:/下载',
        reason: '没设文件夹时先选',
      );
      expect(api.downloadParams!['options']['to'], 1);
      expect(
        (api.downloadParams!['toc'] as List).length,
        2,
        reason: '已读的目录直接交给插件',
      );
      expect(
        (api.downloadParams!['alternates'] as List).single['sourceId'],
        'https://c',
        reason: '其他书源用于补全失败章节',
      );
      api.events_.add({
        'event': 'download.progress',
        'taskId': 't1',
        'stage': 'chapters',
        'progress': {'done': 1, 'total': 1, 'failed': 0, 'current': '第一章'},
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1/1'), findsOneWidget);
      api.events_.add({
        'event': 'download.done',
        'taskId': 't1',
        'result': {
          'outcome': {
            'path': 'D:/下载/剑来 - 烽火.txt',
            'chapters': 1,
            'downloaded': 1,
            'failures': [],
            'cancelled': false,
          },
        },
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('完成'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('booksource-import-t1')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(imported, ['D:/下载/剑来 - 烽火.txt']);
      expect(find.text('已加入书库'), findsOneWidget);
      expect(jsonDecode(File(settings).readAsStringSync())['folder'], 'D:/下载');
      File(settings).deleteSync();
    },
  );

  testWidgets(
    'book source page: check sources, disable failed ones, shelf update, alternates',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeApi();
      // 同一本书有两个书源：下载时把另一个交给插件用于补全。
      api.sourceList.add({
        'id': 'https://c',
        'name': '丙源',
        'group': '',
        'enabled': true,
        'supported': true,
        'reasons': [],
        'webView': false,
        'login': true,
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: BookSourcePage(
              openApi: () async => api,
              settingsPath:
                  '${Directory.systemTemp.path}/ep-bs-ui2-${DateTime.now().microsecondsSinceEpoch}.json',
              chooseFolder: () async => 'D:/下载',
              chooseSourceFile: () async => null,
              importToLibrary: (path) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('书源 2/3'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('booksource-login-https://c')),
        findsOneWidget,
        reason: '有登录设置的书源显示登录',
      );
      await _menu(tester, 'booksource-menu-check');
      await tester.tap(find.byKey(const ValueKey('booksource-check')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('booksource-source-旧版导入-https://a')),
          matching: find.text('未通过校验'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('校验：超时'), findsOneWidget);
      await _menu(tester, 'booksource-menu-maintain');
      await tester.tap(find.byKey(const ValueKey('booksource-disable-failed')));
      await tester.pumpAndSettle();
      expect(api.sourceList[0]['enabled'], isFalse);
      expect(find.textContaining('已停用 1 个'), findsOneWidget);
      await tester.tap(find.text('书架'));
      await tester.pumpAndSettle();
      expect(find.text('+2 新章'), findsOneWidget);
      expect(find.textContaining('最新：第一百零二章'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('booksource-shelf-update-k1')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.calls, contains('library.update'));
      expect(find.textContaining('剑来（追更）'), findsOneWidget);
    },
  );

  testWidgets('plugins page lists permissions and toggles', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('ep-plugin-page-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    makePlugin(Directory('${tmp.path}/b'));
    final registry = PluginRegistry(
      roots: ['${tmp.path}/b'],
      userRoot: '${tmp.path}/u',
      dataRoot: '${tmp.path}/d',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: PluginsPage(registry: registry, chooseFolder: () async => null),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('书源下载'), findsOneWidget);
    expect(find.textContaining('访问网络'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('plugin-enabled-booksource')),
      findsOneWidget,
    );
    await tester.runAsync(() => registry.setEnabled('booksource', true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(registry.isActive('booksource'), isTrue);
    expect(find.text('已启用'), findsOneWidget);
  });
}
