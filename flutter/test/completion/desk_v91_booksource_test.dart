import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desk_v88_booksource_test.dart' as v88;
import 'desk_v89_booksource_test.dart' as v89;
import 'desk_v90_booksource_test.dart' as v90;

/// V91：导入偏好与书架定时检查保存在插件端；两项并发随调用传给插件。
class V91Api extends v90.V90Api {
  Map<String, dynamic> importOptions = {
    'position': 'bottom',
    'overrideName': true,
    'overrideGroup': false,
  };
  Map<String, dynamic> auto = {'hours': 0, 'concurrency': 2, 'lastChecked': 0};
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    switch (method) {
      case 'sources.importOptions.get':
        return importOptions;
      case 'sources.importOptions.set':
        requests.add((method, params));
        importOptions = Map<String, dynamic>.from(params['options'] as Map);
        return importOptions;
      case 'library.autoCheck.get':
        return auto;
      case 'library.autoCheck.set':
        requests.add((method, params));
        auto = {...auto, 'hours': params['hours']};
        return auto;
      case 'sources.importUrl':
        requests.add((method, params));
        return {'added': 2, 'updated': 1, 'skipped': 1, 'total': 9};
      case 'library.check':
        requests.add((method, params));
        return {
          'records': [],
          'newChapters': 0,
          'changedBooks': 0,
          'errors': 0,
        };
    }
    return super.call(method, params);
  }
}

Future<void> _choose(WidgetTester tester, String key, String option) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await v89.pump(tester);
  await tester.tap(find.text(option).last);
  await v89.pump(tester);
}

void main() {
  testWidgets('V91 导入偏好、两项并发与书架定时检查', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v91-settings-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = V91Api();
    await v88.open(tester, api, temp);
    await tester.tap(find.text('设置'));
    await v89.pump(tester);

    // 导入偏好：默认分组不被覆盖；改为放最前、覆盖分组后写给插件。
    final group = find.byKey(const ValueKey('booksource-override-group'));
    await tester.ensureVisible(group);
    expect(tester.widget<Switch>(group).value, false);
    await _choose(tester, 'booksource-import-position', '最前');
    await tester.tap(group);
    await v89.pump(tester);
    expect(api.importOptions, {
      'position': 'top',
      'overrideName': true,
      'overrideGroup': true,
    });

    // 两项并发保存到界面设置。
    await _choose(tester, 'booksource-alternate-concurrency', '4');
    await _choose(tester, 'booksource-update-concurrency', '8');
    final saved =
        jsonDecode(File('${temp.path}/ui.json').readAsStringSync()) as Map;
    expect(saved['alternateConcurrency'], 4);
    expect(saved['updateConcurrency'], 8);

    // 定时检查：选择后写给插件，并带上检查并发。
    await _choose(tester, 'booksource-auto-check', '每 6 小时');
    final set = api.requests.lastWhere((r) => r.$1 == 'library.autoCheck.set');
    expect(set.$2, {'hours': 6, 'concurrency': 8});

    // 手动检查更新也带上并发；书架上能看到定时检查状态。
    await tester.tap(find.text('书架'));
    await v89.pump(tester);
    expect(find.text('定时检查：每 6 小时 · 尚未检查'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('booksource-shelf-check')));
    await v89.pump(tester);
    expect(api.requests.lastWhere((r) => r.$1 == 'library.check').$2, {
      'concurrency': 8,
    });

    // 插件发来的定时检查结果在书架上提示。
    api.events_.add({
      'event': 'library.autoChecked',
      'newChapters': 3,
      'changedBooks': 1,
      'errors': 0,
    });
    await v89.pump(tester);
    expect(find.textContaining('发现 3 个新章节'), findsOneWidget);
    expect(find.textContaining('定时检查：每 6 小时 · 上次'), findsOneWidget);

    // 导入结果写明位置与分组处理（此时偏好为：最前、覆盖分组）。
    await tester.tap(find.textContaining('书源 '));
    await v89.pump(tester);
    await v88.menu(tester, 'booksource-menu-import');
    await tester.tap(find.byKey(const ValueKey('booksource-import-url')));
    await v89.pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('booksource-import-url-field')),
      'https://fixture.invalid/s.json',
    );
    await tester.tap(find.text('导入').last);
    await v89.pump(tester);
    expect(
      find.text('从网址导入：新增 2 个书源（放在最前），更新 1 个，跳过 1 条无法识别的；共 9 个。'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await v89.pump(tester);
  });
}
