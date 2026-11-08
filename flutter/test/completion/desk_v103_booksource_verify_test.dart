// V103 书源界面（LIB-279、LIB-280）：“去验证”单源交互式校验与取消；书源脚本请求搜索、打开登录。
// 全部用假插件与假数据。
import 'dart:async';
import 'dart:io';

import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/plugins/booksource_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desk_v97_booksource_ui_test.dart' as v97;

class V103Api extends v97.V97Api {
  Completer<Map>? check;

  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    switch (method) {
      case 'sources.check' when params['interactive'] == true:
        log.add((method, params));
        check = Completer<Map>();
        return check!.future;
      case 'sources.check.cancel':
        log.add((method, params));
        return {'checkId': params['checkId'], 'cancelled': true};
    }
    return super.call(method, params);
  }
}

Future<V103Api> open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1500, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = V103Api();
  api.sourceList.add({
    'id': 'https://c',
    'name': '丙源',
    'group': '',
    'enabled': true,
    'supported': true,
    'reasons': [],
    'staticWarnings': [],
    'webView': false,
    'login': true,
    'cause': 'verification',
    'check': {
      'ok': false,
      'stage': 'search',
      'error': '需要验证',
      'cause': 'verification',
    },
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: deskTheme(),
      home: Scaffold(
        body: BookSourcePage(
          openApi: () async => api,
          settingsPath:
              '${Directory.systemTemp.path}/ep-v103-${DateTime.now().microsecondsSinceEpoch}.json',
          chooseFolder: () async => 'D:/下载',
          chooseSourceFile: () async => null,
          importToLibrary: (path) async => null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('去验证：单源交互式校验，验证中可取消，结束后恢复（LIB-279）', (tester) async {
    final api = await open(tester);
    await tester.tap(find.text('书源 2/3'));
    await tester.pumpAndSettle();
    final verify = find.byKey(const ValueKey('booksource-verify-https://c'));
    expect(verify, findsOneWidget);
    await tester.tap(verify);
    await v97.settle(tester);
    final call = api.calls_('sources.check').single;
    expect(call['ids'], ['https://c']);
    expect(call['interactive'], true);
    final checkId = call['checkId'] as String;
    expect(checkId, isNotEmpty);
    // 交互式校验前先启用书源交互（验证码等弹窗）。
    expect(api.calls_('source.interaction.enable').last['id'], 'https://c');
    expect(find.text('正在验证，请在弹出的网页里完成；最多等 5 分钟'), findsOneWidget);
    expect(verify, findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('booksource-verify-cancel-https://c')),
    );
    await v97.settle(tester);
    expect(api.calls_('sources.check.cancel').single, {'checkId': checkId});
    // 取消只是信号：原请求收尾后才恢复按钮。
    expect(find.text('正在验证，请在弹出的网页里完成；最多等 5 分钟'), findsOneWidget);
    api.check!.complete({'total': 1, 'done': 1, 'ok': 0, 'cancelled': true});
    await v97.settle(tester);
    expect(find.text('正在验证，请在弹出的网页里完成；最多等 5 分钟'), findsNothing);
    expect(verify, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('书源请求搜索：切到搜索页只搜目标书源；目标不在时回复 false（LIB-280）', (tester) async {
    final api = await open(tester);
    await tester.tap(find.text('书源 2/3'));
    await tester.pumpAndSettle();
    api.events_.add({
      'event': 'source.interaction',
      'source_id': 'https://c',
      'request_id': 'r-search',
      'kind': 'book_search',
      'payload': {'keyword': '剑来', 'scope': null, 'source_id': null},
    });
    await v97.settle(tester);
    final search = api.calls_('search').single;
    expect(search['keyword'] ?? search['key'], '剑来');
    expect(api.calls_('source.interaction.reply').last, {
      'id': 'https://c',
      'request_id': 'r-search',
      'value': true,
    });
    expect(find.textContaining('「丙源」请求搜索“剑来”'), findsOneWidget);

    api.events_.add({
      'event': 'source.interaction',
      'source_id': 'https://c',
      'request_id': 'r-login',
      'kind': 'login_open',
      'payload': {'source_id': 'https://missing'},
    });
    await v97.settle(tester);
    expect(api.calls_('source.interaction.reply').last, {
      'id': 'https://c',
      'request_id': 'r-login',
      'value': false,
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('书源请求打开登录：打开目标书源的登录窗口（LIB-280）', (tester) async {
    final api = await open(tester);
    api.events_.add({
      'event': 'source.interaction',
      'source_id': 'https://c',
      'request_id': 'r-open',
      'kind': 'login_open',
      'payload': {'source_id': null},
    });
    await v97.settle(tester);
    expect(api.calls_('source.loginInfo').last['id'], 'https://c');
    expect(api.calls_('source.interaction.reply').last, {
      'id': 'https://c',
      'request_id': 'r-open',
      'value': true,
    });
    expect(tester.takeException(), isNull);
  });
}
