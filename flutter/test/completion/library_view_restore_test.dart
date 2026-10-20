import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';

import 'library_removal_test.dart' as setup;

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  testWidgets(
    'real app preserves library view across routes, anchors after removal, resets only on successful project replacement',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      const channel = MethodChannel('window_manager');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final data = await t.runAsync(setup.fixture);
      final (state, library, root) = data!;
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      await t.runAsync(() async {
        final paths = <String>[];
        for (var i = 0; i < 24; i++) {
          final file = File('$root/book$i.txt');
          await file.writeAsString('第一章 开始\n正文$i\n');
          paths.add(file.path);
        }
        expect(
          (await library.importFiles(paths)).every((o) => o.succeeded),
          true,
        );
        expect(
          (await library.saveProject('$root/view.easypub.json')).succeeded,
          true,
        );
      });
      await t.pumpWidget(
        RewriteApp(library: library, picker: setup.NoPicker()),
      );
      Future<void> settleWorkspace() async {
        for (var i = 0; i < 300; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          await t.pump(const Duration(milliseconds: 20));
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            await t.pumpAndSettle();
            return;
          }
        }
        fail('workspace initialization did not finish');
      }

      await settleWorkspace();
      final router = GoRouter.of(t.element(find.byType(LibraryPage)));
      Finder search() => find.descendant(
        of: find.byType(LibraryPage),
        matching: find.byType(TextField),
      );
      // V14：书架视图是 GridView，列表视图是 ListView。
      ScrollController scroll() => t
          .widget<BoxScrollView>(
            find
                .descendant(
                  of: find.byType(LibraryPage),
                  matching: find.byWidgetPredicate(
                    (w) => w is ListView || w is GridView,
                  ),
                )
                .first,
          )
          .controller!;
      await t.enterText(search(), 'BoOk');
      await t.tap(find.byTooltip('筛选文件格式'));
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: find.byType(MenuItemButton),
          matching: find.text('TXT'),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('切换列表视图'));
      await t.pumpAndSettle();
      final ids = library.books.value
          .where((b) => b.title.startsWith('book'))
          .map((b) => b.id)
          .toList();
      library.selectBook(ids.first);
      library.checkBooks([ids.first, ids.last], true);
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('筛选书稿'));
      await t.pumpAndSettle();
      await t.tap(find.text('待处理').last);
      await t.pumpAndSettle();
      await t.tap(find.text('仅看已勾选'));
      await t.pumpAndSettle();
      final combined = library.books.value.where(
        (book) =>
            book.format == 'TXT' &&
            book.status != '检查通过' &&
            {ids.first, ids.last}.contains(book.id),
      );
      // V15：数量写在标题“书库”后面，筛选后为“可见 / 全部”。
      expect(
        find.text('${combined.length} / ${library.books.value.length} 本'),
        findsOneWidget,
      );
      for (final book in combined) {
        expect(find.byKey(ValueKey('library-row-${book.id}')), findsOneWidget);
      }
      expect(find.byKey(ValueKey('library-row-${ids[1]}')), findsNothing);
      router.go('/folders');
      await t.pumpAndSettle();
      router.go('/');
      await t.pumpAndSettle();
      // V8：书目行也显示格式列，这里只核对筛选器恢复的值。
      expect(
        find.descendant(
          of: find.byType(DeskFilter<String>).first,
          matching: find.text('TXT'),
        ),
        findsOneWidget,
      );
      expect(find.text('待处理'), findsOneWidget);
      expect(
        t.widget<FilterChip>(find.widgetWithText(FilterChip, '仅看已勾选')).selected,
        true,
      );
      expect(library.selection.value.selected, {ids.first, ids.last});
      await t.tap(find.text('仅看已勾选'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('筛选书稿'));
      await t.pumpAndSettle();
      await t.tap(find.text('全部状态').last);
      await t.pumpAndSettle();
      scroll().jumpTo(8.25 * 76);
      await t.pumpAndSettle();
      final offset = scroll().offset;
      router.go('/folders');
      await t.pumpAndSettle();
      router.go('/');
      await t.pumpAndSettle();
      expect(t.widget<TextField>(search()).controller!.text, 'BoOk');
      // V8：书目行也显示格式列，这里只核对筛选器恢复的值。
      expect(
        find.descendant(
          of: find.byType(DeskFilter<String>).first,
          matching: find.text('TXT'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('切换书架视图'), findsOneWidget);
      expect(scroll().offset, closeTo(offset, 0.5));
      expect(library.selection.value.current, ids.first);
      expect(library.selection.value.selected, {ids.first, ids.last});
      router.go('/folders');
      await t.pumpAndSettle();
      for (var i = 0; i < 100 && state.globalSettingsBusy; i++) {
        await t.pump();
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(state.globalSettingsBusy, false);
      await t.runAsync(() async {
        expect(await library.savePatch({'ui_scale': 1.3}), true);
      });

      library.removeBooks({ids.first});
      router.go('/');
      await t.pumpAndSettle();

      expect(scroll().offset, closeTo((offset - 76) * 1.3, 0.5));
      router.go('/folders');
      await t.pumpAndSettle();
      await t.runAsync(() async {
        expect(
          (await library.openProject('$root/missing.easypub.json')).succeeded,
          false,
        );
      });
      router.go('/');
      await t.pumpAndSettle();
      expect(t.widget<TextField>(search()).controller!.text, 'BoOk');
      // 1.3 倍字号下书架变窄（V84b 有左栏），格式等筛选收进“筛选”菜单；核对菜单记着的值。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is DeskCommandMenu<String> &&
              (w.tooltip ?? '').startsWith('筛选：') &&
              w.tooltip!.contains('TXT'),
        ),
        findsOneWidget,
      );
      await t.runAsync(() async {
        expect(
          (await library.openProject('$root/view.easypub.json')).succeeded,
          true,
        );
      });
      await settleWorkspace();
      expect(t.widget<TextField>(search()).controller!.text, isEmpty);
      // 项目替换后恢复默认的书架视图。
      expect(find.byTooltip('切换列表视图'), findsOneWidget);
      expect(scroll().offset, 0);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
