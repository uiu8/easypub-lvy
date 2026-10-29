// V111 追更后书库里还是旧版本：下载队列提示并给出“刷新来源”，EPUB 不再用旧草稿生成；
// 当前书面板随左栏收起“书稿概览”。界面部分用假插件与假数据，导入判断用真实 Rust。
import 'dart:io';

import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/download_epub.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/plugins/booksource_page.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desk_v97_booksource_ui_test.dart' show V97Api;

class _NoPicker extends Fake implements BookFilePicker {}

class _NoConversion extends Fake implements ConversionSession {}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  testWidgets('下载格式 EPUB：书库里是旧版本时不生成，刷新来源后接着生成', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final api = V97Api();
    final settings = File(
      '${Directory.systemTemp.path}/ep-v111-${DateTime.now().microsecondsSinceEpoch}.json',
    )..writeAsStringSync('{"folder":"D:/下载","downloadFormat":"epub"}');
    addTearDown(settings.deleteSync);
    var outdated = true;
    final exported = <String>[], refreshed = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: BookSourcePage(
            openApi: () async => api,
            settingsPath: settings.path,
            chooseFolder: () async => 'D:/下载',
            chooseSourceFile: () async => null,
            importToLibrary: (path) async => fail('EPUB 模式不单独加入书库'),
            exportEpub: (path) async {
              exported.add(path);
              return (
                imported: true,
                error: outdated ? downloadOutdatedInLibrary : null,
              );
            },
            outdatedInLibrary: (_) => outdated,
            refreshInLibrary: (path) async {
              refreshed.add(path);
              outdated = false;
              return true;
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('booksource-query')), '剑来');
    await t.tap(find.byKey(const ValueKey('booksource-search')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('booksource-result-0')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('booksource-load-toc')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('booksource-download')));
    await t.pump(const Duration(milliseconds: 300));
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
    await _settle(t);
    expect(exported, ['D:/下载/剑来 - 烽火.txt']);
    // 不再显示“已加入书库”，改为“书库里是旧版本”和“刷新来源”。
    expect(find.text('已加入书库'), findsNothing);
    expect(find.text('书库里是旧版本'), findsOneWidget);
    expect(find.text('EPUB：$downloadOutdatedInLibrary'), findsOneWidget);
    expect(find.text('已生成 EPUB'), findsNothing);

    await t.tap(find.byKey(const ValueKey('booksource-refresh-t1')));
    await _settle(t);
    expect(refreshed, ['D:/下载/剑来 - 烽火.txt']);
    expect(exported.length, 2, reason: '采用新内容后接着生成 EPUB');
    expect(find.text('书库里是旧版本'), findsNothing);
    expect(find.text('已加入书库'), findsOneWidget);
    expect(find.text('已生成 EPUB'), findsOneWidget);
    expect(find.textContaining('EPUB：'), findsNothing);
  });

  testWidgets('真实导入：来源内容变化才算旧版本；EPUB 不用旧草稿生成；当前书面板不显示书稿概览', (t) async {
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    t.view.devicePixelRatio = 1;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    late LegacyLibraryAdapter library;
    late PrototypeState state;
    late File txt;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final tmp = (await Directory('../artifacts').createTemp('v111-outdated-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$tmp/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      txt = File('$tmp/剑来 - 烽火.txt')
        ..writeAsStringSync('第一章 开始\n正文一\n第二章 继续\n正文二\n');
      final first = await library.importFiles([txt.path]);
      expect(first.single.succeeded, isTrue);
      expect(first.single.sourceChanged, isFalse);

      final same = await library.importFiles([txt.path]);
      expect(same.single.skipped, isTrue);
      expect(same.single.sourceChanged, isFalse, reason: '内容没变不算旧版本');

      // 追更：同一路径重新拼出更长的 TXT。
      txt.writeAsStringSync('第一章 开始\n正文一\n第二章 继续\n正文二\n第三章 新的\n正文三\n');
      final changed = await library.importFiles([txt.path]);
      expect(changed.single.succeeded, isTrue);
      expect(changed.single.sourceChanged, isTrue);
      expect(library.books.value, hasLength(1), reason: '不新增重复的书');

      final epub = await exportDownloadAsEpub(
        library: library,
        session: _NoConversion(),
        path: txt.path,
      );
      expect(epub.imported, isTrue);
      expect(epub.error, downloadOutdatedInLibrary);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });

    t.view.physicalSize = const Size(1500, 900);
    await t.pumpWidget(RewriteApp(library: library, picker: _NoPicker()));
    for (var i = 0; i < 60; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(find.byKey(const ValueKey('book-summary-open-layout')), findsOne);
    expect(
      find.byKey(const ValueKey('book-summary-open-overview')),
      findsNothing,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
