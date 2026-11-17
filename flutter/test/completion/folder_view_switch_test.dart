import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/folders/folder_book_tools.dart';
import 'package:easypub_desktop/desk/folders/folder_import_dialog.dart';
import 'package:easypub_desktop/desk/folders/folders_page.dart';

import 'library_removal_test.dart' as fixtures;

class FolderPicker extends Fake implements BookFilePicker {
  FolderPicker(this.path);
  final String path;
  @override
  Future<String?> chooseFolder() async => path;
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  for (final dialog in [false, true]) {
    testWidgets('${dialog ? "导入弹窗" : "文件夹页"}切换目录清除筛选和 Shift 连选锚点', (t) async {
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final (state, library, root) = (await t.runAsync(fixtures.fixture))!;
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final large = '$root/large';
      final small = '$root/small';
      await t.runAsync(() async {
        Directory(large).createSync();
        Directory(small).createSync();
        // 只扫描文件信息，不导入这些 EPUB 占位文件。
        for (var i = 0; i < 6; i++) {
          File('$large/0$i.epub').writeAsStringSync('scan fixture');
        }
        File('$large/other.txt').writeAsStringSync('第一章 开始\n正文');
        File('$small/only.txt').writeAsStringSync('第一章 开始\n正文');
      });
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 500; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
          if (ready()) return;
        }
        fail('文件夹界面未就绪');
      }

      final picker = FolderPicker(small);
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: dialog
                ? FolderImportDialog(
                    library: library,
                    picker: picker,
                    initialPath: large,
                  )
                : FoldersPage(
                    library: library,
                    picker: picker,
                    initialFolder: large,
                  ),
          ),
        ),
      );
      FolderListToolbar toolbar() =>
          t.widget<FolderListToolbar>(find.byType(FolderListToolbar).first);
      await until(() => find.text('03.epub').evaluate().isNotEmpty);
      final filter = find.byKey(const ValueKey('folder-type-filter'));
      await t.tap(find.descendant(of: filter, matching: find.text('EPUB')));
      await t.pump();
      expect(toolbar().shown.length, 6);
      await t.tap(find.text('03.epub'));
      await t.pump();
      expect(toolbar().selected.any((p) => p.endsWith('03.epub')), false);
      await t.tap(find.text(dialog ? '浏览文件夹' : '浏览…'));
      await until(() => find.text('only.txt').evaluate().isNotEmpty);
      expect(toolbar().view.type, '');
      expect(toolbar().shown.single.name, 'only.txt');
      expect(filter, findsNothing);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.tap(find.text('only.txt'));
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(t.takeException(), isNull);
      expect(toolbar().selected, isEmpty);
      await t.pumpWidget(const SizedBox());
    });
  }
}
