import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/library/library_view_state.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/dialogs.dart' show DeskAlert;
import 'package:easypub_desktop/desk/tokens.dart';

class Library extends Fake implements LibraryService, BookStatisticsService {
  @override
  final ValueNotifier<bool> importing = ValueNotifier(false);
  @override
  final ValueNotifier<List<BookSummary>> books = ValueNotifier([
    const BookSummary(
      id: 'a',
      title: '美漫斩杀线，但蜘蛛侠 - 除却君身三重雪',
      author: '待补充作者',
      path: 'D:/小说/测试.txt',
      format: 'TXT',
      chapters: 362,
      status: '检查完成 · 有待核对项',
    ),
  ]);
  @override
  final ValueNotifier<BookSelection> selection = ValueNotifier(
    BookSelection('a', {}),
  );
  @override
  void checkBook(String id, bool checked) =>
      selection.value = BookSelection('a', checked ? {id} : {});
  @override
  Future<Map<String, dynamic>> statistics(String id) async => {
    'volumes': 1,
    'chapters': 362,
  };
}

class Picker extends Fake implements BookFilePicker {}

void main() {
  testWidgets(
    'library long title, batch separation and responsive visual review',
    (t) async {
      final library = Library();
      addTearDown(() {
        library.books.dispose();
        library.importing.dispose();
        library.selection.dispose();
      });
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      t.view.devicePixelRatio = 1;
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
      for (final size in [
        const Size(1200, 720),
        const Size(900, 640),
        const Size(720, 600),
      ]) {
        t.view.physicalSize = size;
        final key = GlobalKey();
        String? converted;
        await t.pumpWidget(
          MaterialApp(
            theme: deskTheme(),
            debugShowCheckedModeBanner: false,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Scaffold(
              body: RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: Desk.light.canvas,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: LibraryPage(
                      library: library,
                      picker: Picker(),
                      viewState: LibraryViewState()..compact = true,
                      onConvertBook: (id) => converted = id,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        // V15（LIB-108）：右侧已有详情栏时不再显示“当前书详情”按钮。
        if (find
            .byKey(const ValueKey('library-detail-column'))
            .evaluate()
            .isNotEmpty) {
          expect(find.text('当前书详情'), findsNothing);
        } else {
          await t.tap(find.text('当前书详情'));
          await t.pumpAndSettle();
          expect(find.byType(DeskAlert), findsOneWidget);
          expect(t.takeException(), isNull);
          await t.tap(find.text('关闭'));
          await t.pumpAndSettle();
        }
        expect(find.text('转换所选 0 本'), findsNothing);
        await t.tap(find.text('转换当前书'));
        expect(converted, 'a');
        expect(library.selection.value.selected, isEmpty);
        await t.tap(find.byKey(const ValueKey('library-check-a')));
        await t.pumpAndSettle();
        expect(find.text('转换所选 1 本'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.tap(find.text('清空勾选'));
        await t.pumpAndSettle();
        await t.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../artifacts/library-polish-20261008/library-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await t.pumpWidget(const SizedBox());
      }
    },
  );
}
