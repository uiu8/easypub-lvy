import 'dart:io';

import 'package:easypub_desktop/infrastructure/native_conversion_desktop.dart';

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class NoPicker extends Fake implements BookFilePicker {}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  testWidgets(
    'library filter bulk and shift selection preserve current book and conversion targets',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final captureKey = GlobalKey();
      await t.runAsync(() async {
        await (FontLoader('Microsoft YaHei')..addFont(
              File('C:/Windows/Fonts/msyh.ttc')
                  .readAsBytes()
                  .then((b) => b.buffer.asByteData()),
            ))
            .load();
        await (FontLoader('MaterialIcons')..addFont(
              File(
                'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
      });
      Future<void> capture(String name) async {
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.runAsync(() async {
          final picture =
              await (captureKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final file = File(
            '../design/review-20261005-v2.11/screens/$name.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(
            (await picture.toByteData(format: ui.ImageByteFormat.png))!.buffer
                .asUint8List(),
          );
          picture.dispose();
        });
      }

      late PrototypeState state;
      late LegacyLibraryAdapter library;
      await t.runAsync(() async {
        final dir = await Directory('../artifacts')
            .createTemp('library-selection-');
        state = PrototypeState(
          settingsDirectory: '${dir.absolute.path}/settings',
        );
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        final paths = <String>[];
        for (var i = 0; i < 12; i++) {
          final file = File(
            '${dir.absolute.path}/book${i.toString().padLeft(2, '0')}.txt',
          );
          await file.writeAsString('第一章 开始\n正文$i\n');
          paths.add(file.path);
        }
        final imported = await library.importFiles(paths);
        expect(
          imported.every((r) => r.succeeded),
          true,
          reason: imported.map((r) => r.message).join('\n'),
        );
      });
      expect(t.takeException(), isNull);
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final ids = library.books.value.map((b) => b.id).toList();
      library.selectBook(ids[11]);
      var notifications = 0;
      library.selection.addListener(() => notifications++);
      library.checkBooks([...ids, ids.first, 'missing'], true);
      expect(notifications, 1);
      expect(library.selection.value.selected, ids.toSet());
      library.checkBooks(ids, true);
      expect(notifications, 1);
      library.checkBooks(ids, false);
      expect(notifications, 2);
      Set<String>? conversion;
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          builder: (_, child) =>
              RepaintBoundary(key: captureKey, child: child!),
          theme: deskTheme(),
          home: Scaffold(
            body: LibraryPage(
              library: library,
              picker: NoPicker(),
              onRevealSource: NativeConversionDesktop().revealSource,
              onConvert: () => conversion = library.selection.value.selected,
            ),
          ),
        ),
      );
      await t.tap(find.byKey(ValueKey('library-check-${ids[0]}')));
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.tap(find.byKey(ValueKey('library-check-${ids[3]}')));
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(library.selection.value.selected, ids.take(4).toSet());
      expect(library.selection.value.current, ids[11]);
      await t.enterText(find.byType(TextField), library.books.value[1].title);
      await t.pump();
      expect(find.textContaining('筛选外 3 本'), findsOneWidget);
      await t.tap(find.text('取消筛选结果勾选'));
      await t.pump();
      expect(library.selection.value.selected, {ids[0], ids[2], ids[3]});
      await t.tap(find.text('全选筛选结果'));
      await t.pump();
      expect(library.selection.value.selected, ids.take(4).toSet());
      await t.tap(find.text('转换所选 4 本'));
      expect(conversion, ids.take(4).toSet());
      await t.tap(find.byTooltip('切换紧凑列表'));
      await t.pumpAndSettle();
      expect(library.selection.value.selected, ids.take(4).toSet());
      expect(library.selection.value.current, ids[11]);
      await capture('library-filter-compact');
      await t.enterText(find.byType(TextField), 'missing');
      await t.pump();
      expect(find.textContaining('筛选外 4 本'), findsOneWidget);
      await t.tap(find.text('清空勾选'));
      await t.pump();
      expect(library.selection.value.selected, isEmpty);
      await t.enterText(find.byType(TextField), '');
      await t.pump();
      await t.tap(find.text('全选筛选结果'));
      await t.pump();
      expect(library.selection.value.selected, ids.toSet());
      await capture('library-compact');
      await t.tap(find.byTooltip('更多导入方式'));
      await t.pumpAndSettle();
      await capture('library-import-menu');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('书籍操作：' + library.books.value.first.title));
      await t.pumpAndSettle();
      await capture('library-book-menu');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      final list = find.byType(ListView).first;
      await t.drag(list, const Offset(0, -400));
      await t.pumpAndSettle();
      final before = t.widget<ListView>(list).controller!.offset / 88;
      await t.tap(find.byTooltip('切换封面列表'));
      await t.pumpAndSettle();
      final after = t.widget<ListView>(list).controller!.offset / 132;
      expect(after, closeTo(before, 0.01));
      await capture('library-cover');
      t.view.physicalSize = const Size(1080, 720);
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: deskTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: LibraryPage(library: library, picker: NoPicker()),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('清空勾选'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
