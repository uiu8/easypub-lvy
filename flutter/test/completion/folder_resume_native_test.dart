import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/folders/folder_import_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

import 'library_removal_test.dart' as fixtures;

class UnusedPicker implements BookFilePicker {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'real directory continues past 10000 entries through dialog then imports and reopens',
    (t) async {
      t.view.physicalSize = const Size(1100, 850);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.runAsync(
        () async => RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        ),
      );
      final fixture = await t.runAsync(fixtures.fixture);
      final (state, library, root) = fixture!;
      final initialBooks = library.books.value.map((b) => b.id).toSet();
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final input = Directory('$root/input');
      await t.runAsync(() async {
        await input.create();
        for (var i = 0; i < 10001; i++) {
          File('${input.path}/$i.bin').createSync();
        }
        for (final name in ['甲', '乙']) {
          File('${input.path}/$name.txt')
              .writeAsStringSync('第一章 开始\n$name正文\n');
        }
      });
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 1000; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
          if (ready()) {
            await t.pumpAndSettle();
            return;
          }
        }
        fail('folder operation did not finish');
      }

      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: FolderImportDialog(
              library: library,
              picker: UnusedPicker(),
              initialPath: input.path,
            ),
          ),
        ),
      );
      await until(
        () =>
            find.text('继续扫描 / 重试失败项').evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(library.books.value.map((b) => b.id).toSet(), initialBooks);
      await t.tap(find.text('继续扫描 / 重试失败项'));
      await t.pump();
      await until(
        () =>
            find.text('继续扫描 / 重试失败项').evaluate().isEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(find.textContaining('不支持 10001 个'), findsOneWidget);
      expect(find.text('导入所选 2 本'), findsOneWidget);
      await t.tap(find.text('导入所选 2 本'));
      await t.pump();
      await until(() => find.textContaining('导入 2 本，').evaluate().isNotEmpty);
      expect(library.books.value.length, initialBooks.length + 2);
      await t.runAsync(() async {
        expect(
          (await library.saveProject('$root/resumed.easypub.json')).succeeded,
          true,
        );
        expect(
          (await library.openProject('$root/resumed.easypub.json')).succeeded,
          true,
        );
        expect(library.books.value.length, initialBooks.length + 2);
        for (final name in ['甲', '乙']) {
          expect(
            File('${input.path}/$name.txt').readAsStringSync(),
            '第一章 开始\n$name正文\n',
          );
        }
      });
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
