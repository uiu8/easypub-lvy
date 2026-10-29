import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desk_v88_booksource_test.dart' as v88;
import 'desk_v89_booksource_test.dart' as v89;
import 'desk_v91_booksource_test.dart' as v91;

/// V107：章节缓存位置。插件返回位置、书数与大小；选新位置后插件把已有缓存搬过去。
class V107Api extends v91.V91Api {
  Map<String, dynamic> cache = {
    'path': r'C:\数据\plugin-data\booksource\chapter-cache',
    'defaultPath': r'C:\数据\plugin-data\booksource\chapter-cache',
    'custom': false,
    'bytes': 26 * 1024 * 1024,
    'books': 7,
  };
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    switch (method) {
      case 'cache.location.get':
        return cache;
      case 'cache.location.set':
        requests.add((method, params));
        final path = params['path'] as String?;
        cache = {
          ...cache,
          'path': path ?? cache['defaultPath'],
          'custom': path != null,
          'moved': 7,
          'kept': const [],
        };
        return cache;
    }
    return super.call(method, params);
  }
}

void main() {
  testWidgets('V107 章节缓存位置：显示位置与大小，选新位置后搬过去，可恢复默认', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v107-cache-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V107Api();
    await v88.open(tester, api, temp);
    await tester.tap(find.text('设置'));
    await v89.pump(tester);

    final row = find.byKey(const ValueKey('booksource-cache-location'));
    await tester.ensureVisible(row);
    expect(
      find.text(r'C:\数据\plugin-data\booksource\chapter-cache'),
      findsOneWidget,
    );
    expect(find.textContaining('默认位置 · 7 本书 · 26.0 MB'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('booksource-cache-default')),
      findsNothing,
    );

    // “选择…”用测试的文件夹选择器（返回临时目录）。
    await tester.tap(find.byKey(const ValueKey('booksource-cache-choose')));
    await v89.pump(tester);
    expect(api.requests.last.$1, 'cache.location.set');
    expect(api.requests.last.$2, {'path': temp.path});
    expect(find.text(temp.path), findsOneWidget);
    expect(find.textContaining('自选位置'), findsOneWidget);
    expect(find.textContaining('7 本书的缓存已搬过去'), findsOneWidget);

    // 恢复默认：不带路径。
    await tester.tap(find.byKey(const ValueKey('booksource-cache-default')));
    await v89.pump(tester);
    expect(api.requests.last.$2, isEmpty);
    expect(find.textContaining('默认位置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await v89.pump(tester);
  });
}
