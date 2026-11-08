// V97 书源页界面接线（LIB-211–214）：本机 FQNovel、书源交互弹窗、忘记登录。全部用假插件与假数据。
import 'dart:async';
import 'dart:io';

import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/dialogs.dart';
import 'package:easypub_desktop/desk/plugins/booksource_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desk_v86_plugins_test.dart' as v86;

/// 1×1 透明 PNG。
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

class V97Api extends v86.FakeApi {
  final log = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic> health = {
    'running': false,
    'ready': false,
    'service': null,
    'worker': 'unknown',
    'cause': 'network',
    'next_action': '无法连接本机 FQNovel，请先启动 FQNovel Desktop 并核对端口',
  };
  Completer<Map>? login;
  List<Map<String, dynamic>>? queueTasks;
  List<Map<String, dynamic>> loginUi = [
    {'name': '账号', 'type': 'text'},
    {'name': '密码', 'type': 'password'},
  ];

  List<Map<String, dynamic>> calls_(String method) => [
    for (final (m, p) in log)
      if (m == method) p,
  ];

  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    log.add((method, params));
    switch (method) {
      case 'fqnovel.detect':
        return health;
      case 'fqnovel.import':
        return {
          'imported': true,
          'health': health,
          'subscription': {'added': 3, 'total': 5},
        };
      case 'source.loginInfo':
        return {'ui': loginUi, 'web': false, 'has': true};
      case 'source.login':
        login = Completer<Map>();
        return login!.future;
      case 'queue.list' when queueTasks != null:
        return {'tasks': queueTasks};
      case 'queue.remove':
        queueTasks?.removeWhere((t) => t['id'] == params['taskId']);
        return null;
      case 'source.loginAction':
        // 书源按钮脚本执行时发出提示（如 longToast）。
        events_.add({
          'event': 'source.interaction',
          'source_id': params['id'],
          'request_id': 'r-action',
          'kind': 'notice',
          'payload': {'text': '已切换到模式二', 'long': true},
        });
        return {'ok': true, 'message': '已执行“切换模式”'};
      case 'source.interaction.enable':
        return {'enabled': params['enabled']};
      case 'source.interaction.reply':
      case 'source.loginData.clear':
        return {'ok': true};
    }
    return super.call(method, params);
  }
}

Future<V97Api> open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = V97Api();
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
              '${Directory.systemTemp.path}/ep-v97-${DateTime.now().microsecondsSinceEpoch}.json',
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
  return api;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  testWidgets('LIB-211 本机 FQNovel：先检测，就绪后才可接入，只发端口', (tester) async {
    final api = await open(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-menu-import')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-fqnovel')));
    await settle(tester);
    expect(
      find.byKey(const ValueKey('booksource-fqnovel-dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('只支持本机地址'), findsOneWidget);
    DeskButton importButton() => tester.widget<DeskButton>(
      find.byKey(const ValueKey('booksource-fqnovel-import')),
    );
    expect(importButton().onPressed, isNull, reason: '未检测前不能接入');

    await tester.tap(find.byKey(const ValueKey('booksource-fqnovel-detect')));
    await settle(tester);
    expect(find.text('没有检测到 FQNovel'), findsOneWidget);
    expect(importButton().onPressed, isNull);

    api.health = {
      'running': true,
      'ready': true,
      'service': 'FQNovel Desktop',
      'worker': 'ready',
      'cause': null,
      'next_action': '可接入本机书源',
    };
    await tester.enterText(
      find.byKey(const ValueKey('booksource-fqnovel-port')),
      '19999',
    );
    await tester.tap(find.byKey(const ValueKey('booksource-fqnovel-detect')));
    await settle(tester);
    expect(find.text('FQNovel Desktop · 已就绪'), findsOneWidget);
    expect(api.calls_('fqnovel.detect').last, {'port': 19999});

    await tester.tap(find.byKey(const ValueKey('booksource-fqnovel-import')));
    await settle(tester);
    expect(
      find.byKey(const ValueKey('booksource-fqnovel-dialog')),
      findsNothing,
    );
    expect(api.calls_('fqnovel.import').single, {'port': 19999});
    expect(find.textContaining('本机 FQNovel：新增 3 个书源'), findsOneWidget);
  });

  testWidgets('LIB-212/214 登录：启用交互、upLoginData 取本次字段、忘记登录', (tester) async {
    final api = await open(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-login-https://c')));
    await settle(tester);
    expect(find.textContaining('Windows 账户加密保存在本机'), findsOneWidget);
    final fields = find.descendant(
      of: find.byType(DeskAlert),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), 'demo-user');
    await tester.enterText(fields.at(1), 'fake-pass');
    await tester.tap(find.text('登录').last);
    await settle(tester);
    expect(api.calls_('source.interaction.enable').last, {
      'id': 'https://c',
      'enabled': true,
      'capabilities': ['notice', 'clipboard', 'book_search', 'login_open'],
    });
    // 登录脚本无参调用 upLoginData()：回复本次提交的字段。
    api.events_.add({
      'event': 'source.interaction',
      'source_id': 'https://c',
      'request_id': 'r-login',
      'kind': 'login_data',
      'payload': {},
      'timeout_ms': 120000,
    });
    await settle(tester);
    expect(api.calls_('source.interaction.reply').last, {
      'id': 'https://c',
      'request_id': 'r-login',
      'value': {'账号': 'demo-user', '密码': 'fake-pass'},
    });
    api.login!.complete({'ok': true, 'message': '已执行书源的登录'});
    await settle(tester);
    expect(find.text('已执行书源的登录'), findsOneWidget);

    // 登录结束后再请求字段：取消，不回显任何内容。
    api.events_.add({
      'event': 'source.interaction',
      'source_id': 'https://c',
      'request_id': 'r-late',
      'kind': 'login_data',
      'payload': {},
    });
    await settle(tester);
    expect(api.calls_('source.interaction.reply').last, {
      'id': 'https://c',
      'request_id': 'r-late',
      'cancel': true,
    });

    await tester.tap(find.byKey(const ValueKey('booksource-login-https://c')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-login-forget')));
    await settle(tester);
    expect(api.calls_('source.loginData.clear').single, {'id': 'https://c'});
    expect(find.textContaining('网站上的登录状态（Cookie）不受影响'), findsOneWidget);
  });

  testWidgets('LIB-212/213 验证码、提示、复制与后端关闭', (tester) async {
    final api = await open(tester);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add('${(call.arguments as Map)['text']}');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    void emit(String id, String kind, Map payload) => api.events_.add({
      'event': 'source.interaction',
      'source_id': 'https://a',
      'request_id': id,
      'kind': kind,
      'payload': payload,
      'timeout_ms': 120000,
    });
    Map<String, dynamic> lastReply() =>
        api.calls_('source.interaction.reply').last;

    emit('r-code', 'verification', {'mime': 'image/png', 'image_base64': _png});
    await settle(tester);
    expect(find.text('甲源 需要验证码'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('booksource-verification-field')),
      'ab12',
    );
    await tester.tap(
      find.byKey(const ValueKey('booksource-verification-submit')),
    );
    await settle(tester);
    expect(lastReply(), {
      'id': 'https://a',
      'request_id': 'r-code',
      'value': 'ab12',
    });
    expect(find.byKey(const ValueKey('booksource-verification')), findsNothing);

    // 后端超时关闭：撤下弹窗，不再回复。
    final replies = api.calls_('source.interaction.reply').length;
    emit('r-timeout', 'verification', {
      'mime': 'image/png',
      'image_base64': _png,
    });
    await settle(tester);
    expect(
      find.byKey(const ValueKey('booksource-verification')),
      findsOneWidget,
    );
    api.events_.add({
      'event': 'source.interaction.closed',
      'source_id': 'https://a',
      'request_id': 'r-timeout',
    });
    await settle(tester);
    expect(find.byKey(const ValueKey('booksource-verification')), findsNothing);
    expect(api.calls_('source.interaction.reply').length, replies);

    // 坏图片直接取消。
    emit('r-bad', 'verification', {'mime': 'image/png', 'image_base64': '%%%'});
    await settle(tester);
    expect(lastReply(), {
      'id': 'https://a',
      'request_id': 'r-bad',
      'cancel': true,
    });

    emit('r-notice', 'notice', {'text': '已签到', 'long': false});
    await settle(tester);
    expect(find.text('甲源：已签到'), findsOneWidget);
    expect(lastReply()['value'], isTrue);

    emit('r-copy-no', 'clipboard', {'text': 'fake-token', 'long': false});
    await settle(tester);
    expect(find.text('甲源 请求复制文字'), findsOneWidget);
    await tester.tap(find.text('不复制'));
    await settle(tester);
    expect(lastReply()['value'], isFalse);
    expect(copied, isEmpty, reason: '用户拒绝时不写剪贴板');

    emit('r-copy', 'clipboard', {'text': 'fake-token', 'long': false});
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-clipboard-copy')));
    await settle(tester);
    expect(copied, ['fake-token']);
    expect(lastReply(), {
      'id': 'https://a',
      'request_id': 'r-copy',
      'value': true,
    });
  });

  testWidgets('LIB-215 下载格式选 EPUB：下载完生成 EPUB，失败可重试', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = V97Api();
    final settings = File(
      '${Directory.systemTemp.path}/ep-v97-epub-${DateTime.now().microsecondsSinceEpoch}.json',
    )..writeAsStringSync('{"folder":"D:/下载"}');
    addTearDown(settings.deleteSync);
    final exported = <String>[];
    var busy = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: BookSourcePage(
            openApi: () async => api,
            settingsPath: settings.path,
            chooseFolder: () async => 'D:/下载',
            chooseSourceFile: () async => null,
            importToLibrary: (path) async => fail('EPUB 模式不再单独加入书库'),
            exportEpub: (path) async {
              exported.add(path);
              return busy
                  ? (imported: true, error: '另一项转换正在进行。')
                  : (imported: true, error: null);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('booksource-download-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EPUB（全局默认排版）').last);
    await tester.pumpAndSettle();
    expect(settings.readAsStringSync(), contains('"downloadFormat":"epub"'));

    await tester.tap(find.text('搜索').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('booksource-query')),
      '剑来',
    );
    await tester.tap(find.byKey(const ValueKey('booksource-search')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('booksource-result-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('booksource-load-toc')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('booksource-download')));
    await tester.pump(const Duration(milliseconds: 300));
    api.events_.add({
      'event': 'download.done',
      'taskId': 't1',
      'result': {
        'outcome': {
          'path': 'D:/下载/剑来 - 烽火.txt',
          'chapters': 2,
          'downloaded': 2,
          'failures': [],
          'cancelled': false,
        },
      },
    });
    await settle(tester);
    expect(exported, ['D:/下载/剑来 - 烽火.txt']);
    expect(find.text('EPUB：另一项转换正在进行。'), findsOneWidget);
    expect(find.text('已加入书库'), findsOneWidget);

    busy = false;
    await tester.tap(find.byKey(const ValueKey('booksource-task-menu-t1')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-epub-t1')));
    await settle(tester);
    expect(exported.length, 2);
    expect(find.text('已生成 EPUB'), findsOneWidget);
    expect(find.textContaining('EPUB：'), findsNothing);
  });

  testWidgets('LIB-216 只有按钮的登录界面：按序号执行书源动作，提示显示在登录框里', (tester) async {
    final api = await open(tester);
    api.loginUi = [
      {'name': '切换模式', 'type': 'button', 'action': 'fqCycle()'},
      {'name': '查看状态', 'type': 'button', 'action': 'fqState()'},
    ];
    await tester.tap(find.byKey(const ValueKey('booksource-login-https://c')));
    await settle(tester);
    expect(
      find.descendant(
        of: find.byType(DeskAlert),
        matching: find.byType(TextField),
      ),
      findsNothing,
    );
    expect(find.text('登录'), findsWidgets);
    expect(find.byKey(const ValueKey('booksource-login-forget')), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('booksource-login-action-0')));
    await settle(tester);
    expect(api.calls_('source.interaction.enable').last['id'], 'https://c');
    expect(api.calls_('source.loginAction').single, {
      'id': 'https://c',
      'index': 0,
    });
    expect(find.text('已切换到模式二'), findsOneWidget);
    expect(api.calls_('source.interaction.reply').last['value'], isTrue);
    await tester.tap(find.text('关闭'));
    await settle(tester);
    expect(api.calls_('source.login'), isEmpty, reason: '只有按钮时不调用登录');
  });

  testWidgets('LIB-219～221 收藏书源、收藏快捷搜索、选择文件里的单个或几个书源', (tester) async {
    final api = await open(tester);
    await tester.tap(
      find.byKey(const ValueKey('booksource-favorite-https://a')),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('booksource-node-fav')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('booksource-node-fav')));
    await settle(tester);
    expect(find.text('丙源'), findsNothing, reason: '收藏节点只列收藏的书源');

    await tester.tap(find.text('搜索').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('booksource-favorites-scope')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('booksource-query')),
      '剑来',
    );
    await tester.tap(find.byKey(const ValueKey('booksource-search')));
    await tester.pumpAndSettle();
    var params = api.calls_('search').last;
    expect(params['sourceIds'], ['https://a']);
    expect(params['onlyPriority'], isFalse);
    expect(params['quick'], isFalse);

    await tester.tap(find.byKey(const ValueKey('booksource-search-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择书源…').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('booksource-pick-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('booksource-pick-file-旧版导入')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('booksource-pick-https://b')),
      findsNothing,
      reason: '不支持的书源不列出',
    );
    await tester.tap(find.byKey(const ValueKey('booksource-pick-https://c')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('booksource-pick-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('只搜：丙源'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('booksource-search')));
    await tester.pumpAndSettle();
    params = api.calls_('search').last;
    expect(params['sourceIds'], ['https://c']);
    expect(params['includeWebView'], isTrue);

    await tester.tap(find.byKey(const ValueKey('booksource-picked-chip')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('booksource-pick-file-check-旧版导入')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('booksource-pick-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 个书源'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('booksource-search')));
    await tester.pumpAndSettle();
    expect((api.calls_('search').last['sourceIds'] as List).toSet(), {
      'https://a',
      'https://c',
    });
  });

  testWidgets('LIB-223 单独清除一条下载记录：进行中的不能清除，清除后文件保留的说明', (tester) async {
    final api = await open(tester);
    Map<String, dynamic> task(String id, String title, String status) => {
      'id': id,
      'title': title,
      'sourceName': '甲源',
      'status': status,
      'chapters': [],
      'progress': {'done': 1, 'total': 2},
      'error': null,
      'result': null,
    };
    api.queueTasks = [
      task('t-done', '剑来', 'done'),
      task('t-run', '神通者', 'running'),
    ];
    await tester.tap(find.byKey(const ValueKey('booksource-tab-downloads')));
    await settle(tester);
    api.events_.add({
      'event': 'queue.changed',
      'queue': {'tasks': api.queueTasks},
    });
    await settle(tester);
    expect(
      find.byKey(const ValueKey('booksource-task-t-done')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('booksource-task-menu-t-run')));
    await settle(tester);
    await tester.tap(
      find.byKey(const ValueKey('booksource-remove-t-run')),
      warnIfMissed: false,
    );
    await settle(tester);
    expect(api.calls_('queue.remove'), isEmpty, reason: '正在下载的不能清除');
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('booksource-task-menu-t-done')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('booksource-remove-t-done')));
    await settle(tester);
    expect(api.calls_('queue.remove').single, {'taskId': 't-done'});
    expect(find.byKey(const ValueKey('booksource-task-t-done')), findsNothing);
    expect(find.byKey(const ValueKey('booksource-task-t-run')), findsOneWidget);
    expect(find.textContaining('下载的文件保留'), findsOneWidget);
  });
}
