import 'package:easypub_desktop/application/folder_count_service.dart';
import 'package:easypub_desktop/infrastructure/native_folder_count.dart';

import 'dart:io';
import 'dart:async';

import 'package:flutter/services.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/conversion/output_folder_dialog.dart';

class Library extends Fake implements LibraryService, FolderCountService {
  int countCalls = 0;
  FolderCount countResult = const FolderCount(18, true, '本层电子书文件');
  bool Function()? countCancelled;
  @override
  Future<FolderCount> countFolder(
    String path, {
    required bool Function() cancelled,
  }) async {
    countCalls++;
    countCancelled = cancelled;
    return countResult;
  }

  @override
  final ValueNotifier<List<String>> favoriteFolders =
      ValueNotifier<List<String>>([r'D:\Books\Kindle']);
  @override
  final ValueNotifier<Map<String, String>> favoriteNames =
      ValueNotifier<Map<String, String>>({r'D:\Books\Kindle': 'Kindle 成品'});
  bool fail = false;
  Completer<bool>? pendingLoad;
  @override
  String favoriteName(String path) =>
      favoriteNames.value[path] ?? path.split('\\').last;
  @override
  Future<bool> loadFavorites() async =>
      pendingLoad == null ? true : await pendingLoad!.future;
  @override
  Future<bool> setFavorite(String path, bool value) async {
    if (fail) return false;
    favoriteFolders.value = value
        ? {...favoriteFolders.value, path}.toList()
        : favoriteFolders.value.where((p) => p != path).toList();
    return true;
  }

  @override
  Future<bool> renameFavorite(String path, String name) async {
    favoriteNames.value = {...favoriteNames.value, path: name};
    return true;
  }
}

class Picker extends Fake implements BookFilePicker {
  String? path;
  @override
  Future<String?> chooseFolder() async => path;
}

void main() {
  testWidgets('partial and failed counts never masquerade as exact zero', (
    tester,
  ) async {
    final library = Library(), picker = Picker();
    for (final result in [
      const FolderCount(7, false, '达到统计上限'),
      const FolderCount(0, false, '无法读取'),
      const FolderCount(0, true, '空目录'),
    ]) {
      library.countResult = result;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: OutputFolderDialog(
              key: ValueKey(result),
              library: library,
              picker: picker,
              initialPath: '',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          result.complete
              ? '0 本'
              : result.count > 0
              ? '≥7 本'
              : '未统计',
        ),
        findsOneWidget,
      );
      expect(find.byTooltip(result.detail), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  test('native count includes four formats, ignores descendants, and distinguishes incomplete scans', () async {
    final root = await Directory.systemTemp.createTemp('easypub-count-');
    try {
      for (final name in ['a.txt', 'b.EPUB', 'c.mobi', 'd.AZW3', 'cover.jpg']) {
        await File('${root.path}/$name').writeAsString('protected');
      }
      final sub = await Directory('${root.path}/sub').create();
      await File('${sub.path}/nested.txt').writeAsString('protected');
      final count = await const NativeFolderCount().countFolder(
        root.path,
        cancelled: () => false,
      );
      expect(count.complete, isTrue);
      expect(count.count, 4);
      final bounded = await const NativeFolderCount(entryLimit: 2)
          .countFolder(root.path, cancelled: () => false);
      expect(bounded.complete, isFalse);
      expect(bounded.count, lessThanOrEqualTo(2));
      expect(
        (await const NativeFolderCount().countFolder(
          root.path,
          cancelled: () => true,
        )).complete,
        isFalse,
      );
      expect(
        (await const NativeFolderCount().countFolder(
          '${root.path}/missing',
          cancelled: () => false,
        )).complete,
        isFalse,
      );
      expect(await File('${root.path}/a.txt').readAsString(), 'protected');
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    'real DLL favorites persist rename and removal without changing files',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File('../target/release/easypub_bridge.dll').absolute.path,
        ),
      );
      final root = await Directory(
        '../artifacts/frontend-rewrite/output-folder',
      ).create(recursive: true);
      final run = await root.createTemp('run-');
      final folder = await Directory('${run.path}/books').create();
      final source = await File('${folder.path}/protected.txt')
          .writeAsString('原稿不能改变');
      final settings = '${run.absolute.path}/settings';
      final state = PrototypeState(settingsDirectory: settings);
      final library = LegacyLibraryAdapter(backend: state);
      expect(await library.setFavorite(folder.absolute.path, true), isTrue);
      final counted = await library.countFolder(
        folder.absolute.path,
        cancelled: () => false,
      );
      expect(counted.complete, isTrue);
      expect(counted.count, 1);
      expect(
        await library.renameFavorite(folder.absolute.path, 'Kindle 成品'),
        isTrue,
      );
      final reopenedState = PrototypeState(settingsDirectory: settings);
      final reopened = LegacyLibraryAdapter(backend: reopenedState);
      expect(await reopened.loadFavorites(), isTrue);
      expect(reopened.favoriteName(folder.absolute.path), 'Kindle 成品');
      expect(await reopened.setFavorite(folder.absolute.path, false), isTrue);
      expect(reopened.favoriteFolders.value, isEmpty);
      expect(await folder.exists(), isTrue);
      expect(await source.readAsString(), '原稿不能改变');
      reopened.dispose();
      library.dispose();
      reopenedState.dispose();
      state.dispose();
    },
  );
  testWidgets(
    'selection requires confirmation; favorites can be renamed, removed, and browsed',
    (tester) async {
      final library = Library(), picker = Picker();
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) => OutputFolderDialog(
                      library: library,
                      picker: picker,
                      initialPath: r'D:\original',
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
      }

      await open();
      expect(find.text('18 本'), findsOneWidget);
      final initialCountCalls = library.countCalls;
      await tester.pump();
      expect(library.countCalls, initialCountCalls);
      await tester.tap(find.text('Kindle 成品'));
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(library.countCancelled!(), isTrue);
      await open();
      await tester.tap(find.text('Kindle 成品'));
      await tester.pump();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '我的 Kindle');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(library.favoriteName(r'D:\Books\Kindle'), '我的 Kindle');
      await tester.tap(find.text('取消收藏'));
      await tester.pumpAndSettle();
      expect(library.favoriteFolders.value, isEmpty);
      // Removing the shortcut does not discard the selected output location.
      await tester.tap(find.text('使用此文件夹'));
      await tester.pumpAndSettle();
      expect(result, r'D:\Books\Kindle');
      await open();
      picker.path = r'D:\new-output';
      await tester.tap(find.text('添加收藏'));
      await tester.pumpAndSettle();
      expect(library.favoriteFolders.value, [picker.path]);
      await tester.enterText(find.byType(TextField), 'no-match');
      await tester.pump();
      expect(find.text('没有匹配的收藏，可浏览其他文件夹。'), findsOneWidget);
      picker.path = r'D:\browse-only';
      await tester.tap(find.text('浏览其他文件夹'));
      await tester.pumpAndSettle();
      expect(find.text(r'D:\browse-only'), findsOneWidget);
      expect(find.text(r'D:\original'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.tap(find.text('使用此文件夹'));
      await tester.pumpAndSettle();
      expect(result, picker.path);
      expect(library.favoriteFolders.value, [r'D:\new-output']);
      await open();
      library.fail = true;
      await tester.tap(find.text('添加收藏'));
      await tester.pumpAndSettle();
      expect(find.text('操作未完成，请检查文件夹或稍后重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'short window, keyboard selection, cancellation and busy close protection',
    (tester) async {
      tester.view.physicalSize = const Size(700, 450);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = Library(), picker = Picker();
      library.pendingLoad = Completer<bool>();
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => OutputFolderDialog(
                      library: library,
                      picker: picker,
                      initialPath: r'D:\original',
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
      await Navigator.of(tester.element(find.byType(OutputFolderDialog)))
          .maybePop();
      await tester.pump();
      expect(find.byType(OutputFolderDialog), findsOneWidget);
      library.pendingLoad!.complete(true);
      await tester.pumpAndSettle();
      final row = find
          .ancestor(of: find.text('Kindle 成品'), matching: find.byType(InkWell))
          .first;
      await tester.ensureVisible(row);
      Focus.of(
        tester.element(
          find.descendant(of: row, matching: find.byType(Text)).first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        find.descendant(of: row, matching: find.text('输出位置')),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('浏览其他文件夹'));
      await tester.tap(find.text('浏览其他文件夹'));
      await tester.pumpAndSettle();
      // Native picker cancellation preserves the selected location.
      expect(
        find.descendant(of: row, matching: find.text('输出位置')),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('使用此文件夹'));
      await tester.tap(find.text('使用此文件夹'));
      await tester.pumpAndSettle();
      expect(result, r'D:\Books\Kindle');
      expect(tester.takeException(), isNull);
    },
  );
}
