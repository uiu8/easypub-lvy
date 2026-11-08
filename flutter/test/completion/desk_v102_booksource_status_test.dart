// V102 书源状态显示（LIB-271～273）：静态告警只作提示、连接失败细分、运行时未支持接口与脚本错误、
// 书源详情“最近一次校验”。全部用假插件与假数据。
import 'dart:io';

import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/plugins/booksource_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desk_v86_plugins_test.dart' as v86;

class V102Api extends v86.FakeApi {
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (method == 'sources.detail') {
      return {'url': params['id'], 'tags': [], 'health': {}, 'learned': {}};
    }
    return super.call(method, params);
  }
}

void main() {
  Future<V102Api> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = V102Api();
    api.sourceList
      ..clear()
      ..addAll([
        {
          'id': 'https://cert',
          'name': '证书源',
          'group': '',
          'enabled': true,
          'supported': true,
          'reasons': [],
          'staticWarnings': [],
          'webView': false,
          'cause': 'network',
          'check': {
            'ok': false,
            'stage': 'search',
            'error': '连接失败',
            'cause': 'network',
            'networkFailure': 'certificate_expired',
            'keywordOrigin': 'source',
            'searchAttempts': 2,
          },
        },
        {
          'id': 'https://warn',
          'name': '提示源',
          'group': '',
          'enabled': true,
          'supported': true,
          'reasons': ['脚本用了尚未支持的函数 java.xxx'],
          'staticWarnings': ['脚本用了尚未支持的函数 java.xxx'],
          'webView': false,
        },
        {
          'id': 'https://api',
          'name': '接口源',
          'group': '',
          'enabled': true,
          'supported': true,
          'reasons': [],
          'staticWarnings': [],
          'webView': false,
          'cause': 'unsupported',
          'check': {
            'ok': false,
            'stage': 'content',
            'error': '插件不支持的写法',
            'cause': 'unsupported',
            'unsupportedInterface': 'java.fooBar',
          },
        },
        {
          'id': 'https://json',
          'name': '数据源',
          'group': '',
          'enabled': true,
          'supported': true,
          'reasons': [],
          'staticWarnings': [],
          'webView': false,
          'cause': 'rule',
          'check': {
            'ok': false,
            'stage': 'toc',
            'error': '解析失败',
            'cause': 'rule',
            'diagnostic': 'script_json_error',
          },
        },
        {
          'id': 'https://comic',
          'name': '漫画源',
          'group': '',
          'enabled': true,
          'supported': false,
          'reasons': ['漫画书源，暂只支持文字书源'],
          'staticWarnings': ['漫画书源，暂只支持文字书源'],
          'webView': false,
        },
      ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: BookSourcePage(
            openApi: () async => api,
            settingsPath:
                '${Directory.systemTemp.path}/ep-v102-${DateTime.now().microsecondsSinceEpoch}.json',
            chooseFolder: () async => 'D:/下载',
            chooseSourceFile: () async => null,
            importToLibrary: (path) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('书源 5/5'));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('列表：细分原因、未支持接口、脚本错误；静态告警只标“兼容提示”', (tester) async {
    await open(tester);
    expect(find.text('校验（搜索）：连接失败 · 证书已过期或尚未生效'), findsOneWidget);
    expect(
      find.text('校验（正文）：插件不支持的写法 · 调用了尚未支持的接口 java.fooBar'),
      findsOneWidget,
    );
    expect(find.text('校验（目录）：解析失败 · 网站返回的不是有效 JSON（多半是网站变了）'), findsOneWidget);
    // 能试跑的书源只标“兼容提示”，“不能用”只留给非文字书源。
    expect(find.text('兼容提示'), findsOneWidget);
    expect(find.text('不能用'), findsOneWidget);
    expect(find.text('可能用到未支持的写法，校验时才知道是否真的用到'), findsOneWidget);
    expect(find.text('漫画书源，暂只支持文字书源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('书源详情：最近一次校验写结果、原因、校验词', (tester) async {
    await open(tester);
    await tester.tap(find.text('证书源'));
    await tester.pumpAndSettle();
    final section = find.byKey(const ValueKey('booksource-last-check'));
    expect(section, findsOneWidget);
    Finder within(String text) =>
        find.descendant(of: section, matching: find.text(text));
    expect(within('未通过 · 停在搜索'), findsOneWidget);
    expect(within('连接失败 · 证书已过期或尚未生效'), findsOneWidget);
    expect(within('书源自带的校验词，共试了 2 次'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
