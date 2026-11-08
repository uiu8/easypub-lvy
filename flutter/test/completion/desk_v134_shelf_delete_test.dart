import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/plugins/booksource_page.dart';

import 'desk_v88_booksource_test.dart' as v88;

/// 书架里的这本书指向临时目录里的真实文件（假数据）。
class ShelfApi extends v88.V88Api {
  ShelfApi(this.txt);
  final String txt;
  bool removed = false;
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (method == 'library.list') {
      return removed
          ? []
          : [
              {
                'key': 'k1',
                'sourceId': 'https://a',
                'sourceName': '甲源',
                'book': {'name': '测试书', 'author': '作者甲'},
                'chapters': 10,
                'path': txt,
              },
            ];
    }
    if (method == 'library.remove') {
      removed = true;
      requests.add((method, params));
      return null;
    }
    return super.call(method, params);
  }
}

/// V134：书源书架可以真正删除下载的书。
void main() {
  testWidgets('删除下载的书：删记录与缓存，文件交给回收站、同时移出书库', (tester) async {
    final temp = Directory.systemTemp.createTempSync('v134-shelf-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final txt = '${temp.path}${Platform.pathSeparator}测试书 - 作者甲.txt';
    File(txt).writeAsStringSync('假数据');
    final cover = '${temp.path}${Platform.pathSeparator}测试书 - 作者甲.jpg';
    File(cover).writeAsStringSync('假图');
    final api = ShelfApi(txt);
    final deleted = <(List<String>, bool)>[];
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
            inLibrary: (path) => path == txt,
            deleteDownload:
                (files, {required path, required removeFromLibrary}) async {
                  deleted.add((files, removeFromLibrary));
                  return null;
                },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('书架'));
    await tester.pump(const Duration(milliseconds: 300));
    await v88.menu(tester, 'booksource-shelf-menu-k1');
    await tester.tap(find.byKey(const ValueKey('booksource-shelf-delete-k1')));
    await tester.pump(const Duration(milliseconds: 400));
    // 文件与书库两项默认都勾上，列出 TXT 与同名封面。
    expect(find.text('删除“测试书”？'), findsOneWidget);
    expect(find.textContaining('测试书 - 作者甲.jpg'), findsOneWidget);
    final files = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('booksource-delete-files')),
    );
    expect(files.value, true);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('booksource-delete-library')),
          )
          .value,
      true,
    );
    await tester.tap(find.byKey(const ValueKey('booksource-delete-confirm')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.requests.any((r) => r.$1 == 'library.remove'), isTrue);
    expect(deleted, hasLength(1));
    expect(deleted.single.$1, [txt, cover]);
    expect(deleted.single.$2, true);
    expect(find.textContaining('文件已移到回收站'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
