import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/folder_auto_import.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/folders/folders_page.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

class _NoPicker implements BookFilePicker {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(PrototypeState, LegacyLibraryAdapter, String)> _fixture() async {
  final root = (await Directory('../artifacts').createTemp('v26-auto-'))
      .absolute
      .path;
  final state = PrototypeState(settingsDirectory: '$root/settings');
  final library = LegacyLibraryAdapter(backend: state);
  await library.load();
  await library.savePatch({'check_after_import': false});
  return (state, library, root);
}

void _book(String folder, String name) =>
    File('$folder/$name.txt').writeAsStringSync('第一章 开始\n$name的正文。\n');

/// V26：文件夹自动入库（FOLD-080–082）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('路径归属：子文件夹算在内，同名前缀不算，不分大小写与斜杠', () {
    expect(pathInside(r'D:\书\甲.txt', 'D:/书'), true);
    expect(pathInside(r'D:\书\子\乙.txt', r'D:\书\'), true);
    expect(pathInside(r'd:\书\甲.TXT', r'D:\书'), true);
    expect(pathInside(r'D:\书库\甲.txt', r'D:\书'), false);
    expect(pathInside(r'D:\书', r'D:\书'), false);
  });

  test('开启后导入新书；移除过的不再导入；原稿被删只标记缺失；关闭后不再同步', () async {
    final (state, library, root) = await _fixture();
    try {
      final folder = '$root/自动入库';
      Directory(folder).createSync();
      _book(folder, '甲');
      _book(folder, '乙');
      expect(await library.setAutoImport(folder, true), true);
      // 开启时立即同步一次（不依赖文件监听）。
      await library.syncAutoImport();
      expect(library.autoImportFolders.value, [folder]);
      expect(library.books.value.map((b) => b.title), containsAll(['甲', '乙']));
      expect(
        library.autoImportState.value.added,
        containsAll(['甲.txt', '乙.txt']),
      );
      library.acknowledgeAutoImport();
      expect(library.autoImportState.value.added, isEmpty);

      // 新出现的书在下次同步时导入；已有的不重复导入。
      _book(folder, '丙');
      await library.syncAutoImport();
      expect(library.books.value.where((b) => b.title == '甲'), hasLength(1));
      expect(library.autoImportState.value.added, ['丙.txt']);

      // 从书库移除的书记入忽略列表，不再自动导入。
      final yi = library.books.value.singleWhere((b) => b.title == '乙');
      library.removeBooks({yi.id});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        (state.globalConfiguration['auto_import_ignored'] as List).single,
        yi.path,
      );
      await library.syncAutoImport();
      expect(library.books.value.where((b) => b.title == '乙'), isEmpty);

      // 原稿被删：书仍在书库，只标记缺失。
      final jia = library.books.value.singleWhere((b) => b.title == '甲');
      File(jia.path).deleteSync();
      await library.syncAutoImport();
      expect(library.books.value.any((b) => b.id == jia.id), true);
      expect(library.autoImportState.value.missing, {jia.id});
      expect(library.autoImportState.value.message, contains('1 本原稿缺失'));

      // 关闭后不再导入。
      expect(await library.setAutoImport(folder, false), true);
      _book(folder, '丁');
      await library.syncAutoImport();
      expect(library.books.value.where((b) => b.title == '丁'), isEmpty);
      expect(library.autoImportState.value.missing, isEmpty);
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  test('运行中监听文件夹：放进新书后自动导入（停 2 秒后合并同步）', () async {
    final (state, library, root) = await _fixture();
    try {
      final folder = '$root/监听';
      Directory(folder).createSync();
      await library.setAutoImport(folder, true);
      await library.syncAutoImport();
      _book(folder, '戊');
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (library.books.value.any((b) => b.title == '戊')) break;
      }
      expect(library.books.value.any((b) => b.title == '戊'), true);
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  testWidgets('收藏文件夹行的自动入库开关（FOLD-080）', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String folder;
    await t.runAsync(() async {
      final f = await _fixture();
      (state, library, _) = f;
      folder = '${f.$3}/收藏';
      Directory(folder).createSync();
      await library.setFavorite(folder, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: FoldersPage(library: library, picker: _NoPicker()),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 300));
    final toggle = find.byKey(ValueKey('favorite-auto-import-$folder'));
    expect(toggle, findsOneWidget);
    expect(find.byTooltip(RegExp(r'^自动入库：关')), findsOneWidget);
    await t.tap(toggle);
    for (var i = 0; i < 40 && library.autoImportFolders.value.isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
    }
    expect(library.autoImportFolders.value, [folder]);
    await t.pump();
    final tips = t
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((w) => w.message)
        .toList();
    expect(find.byTooltip(RegExp(r'^自动入库：开')), findsOneWidget, reason: '$tips');
    await t.pumpWidget(const SizedBox());
  });
}
