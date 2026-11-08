import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desk_v88_booksource_test.dart' as v88;
import 'desk_v89_booksource_test.dart' as v89;

/// V108：重置书源运行状态（设备、临时 Cookie 与缓存），登录信息保留。
class V108Api extends v89.V89Api {
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (method == 'source.reset') {
      requests.add((method, params));
      if (params['id'] == 'https://b') throw '没有这个书源';
      return {'cleared': 1};
    }
    return super.call(method, params);
  }
}

void main() {
  testWidgets('V108 书源行菜单“重置设备与运行状态”：调插件并提示，失败时说明原因', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v108-reset-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V108Api();
    await v88.open(tester, api, temp);
    await tester.tap(find.text('书源 1/2'));
    await v89.pump(tester);

    await v88.menu(tester, 'booksource-row-menu-https://a');
    await tester.tap(find.byKey(const ValueKey('booksource-reset-https://a')));
    await v89.pump(tester);
    expect(api.requests.last.$1, 'source.reset');
    expect(api.requests.last.$2, {'id': 'https://a'});
    expect(find.textContaining('下次搜索或下载时重新生成设备'), findsOneWidget);

    await v88.menu(tester, 'booksource-row-menu-https://b');
    await tester.tap(find.byKey(const ValueKey('booksource-reset-https://b')));
    await v89.pump(tester);
    expect(find.textContaining('没有重置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await v89.pump(tester);
  });
}
