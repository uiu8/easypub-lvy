import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/library/book_structure_counts.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

import '../test/completion/library_removal_test.dart' as setup;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

class FailingStatistics extends Fake
    implements LibraryService, BookStatisticsService {
  int calls = 0;
  @override
  Future<Map<String, dynamic>> statistics(String id) async {
    if (++calls == 1) throw const FormatException('read failed');
    return {'volumes': 0, 'chapters': 3};
  }
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test('live effective statistics reuse requests and follow volume edit, undo, redo and project reopen', () async {
    final (state, library, root) = await setup.fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = library.books.value.first.id;
    final file = File(library.books.value.first.path);
    final original = await file.readAsBytes();
    final one = library.statistics(id);
    expect(identical(one, library.statistics(id)), true);
    final initial = await one;
    expect(initial['volumes'], 0);
    expect(initial['chapters'], 1);
    final version = library.books.value.first.contentVersion;
    final chapters = library.openChapters(id);
    var page = await chapters.read(0);
    await chapters.confirm(
      await chapters.preview(
        page,
        InsertChapterVolume(page.nodes.first.id, '第一卷 测试'),
      ),
    );
    expect(library.books.value.first.contentVersion, isNot(version));
    final after = await library.statistics(id);
    expect(after['volumes'], 1);
    expect(after['chapters'], 1);
    expect(after['characters'], initial['characters']);
    final overview = await library.overview(id);
    for (final key in ['volumes', 'chapters', 'characters']) {
      expect(overview[key], after[key]);
    }
    await chapters.history(await chapters.read(0), undo: true);
    expect((await library.statistics(id))['volumes'], 0);
    await chapters.history(await chapters.read(0), undo: false);
    expect((await library.statistics(id))['volumes'], 1);
    expect(
      (await library.saveProject('$root/statistics.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/statistics.easypub.json')).succeeded,
      true,
    );
    expect(await library.statistics(id), after);
    expect(await file.readAsBytes(), original);
  });
  testWidgets(
    'statistics failure is visible and retry does not invent zero counts',
    (t) async {
      final service = FailingStatistics();
      const book = BookSummary(
        id: 'a',
        title: '甲',
        author: '作者',
        path: 'a.txt',
        format: 'TXT',
        chapters: 999,
        status: '',
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookStructureCounts(library: service, book: book),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('统计读取失败，点击重试'), findsOneWidget);
      expect(find.textContaining('999'), findsNothing);
      await t.tap(find.text('统计读取失败，点击重试'));
      await t.pumpAndSettle();
      expect(find.text('0 卷 · 3 章'), findsOneWidget);
    },
  );
  testWidgets(
    'list and summary refresh effective counts together after editing',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final captureKey = GlobalKey();
      await t.runAsync(() async {
        await (FontLoader('Microsoft YaHei')..addFont(File('C:/Windows/Fonts/msyh.ttc').readAsBytes().then((b) => b.buffer.asByteData()))).load();
        await (FontLoader('MaterialIcons')..addFont(File('D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytes().then((b) => b.buffer.asByteData()))).load();
      });
      Future<void> capture(String name) async {
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.runAsync(() async {
          final picture = await (captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
          final file = File('../design/review-20261005-v2.14/screens/' + name + '.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes((await picture.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
          picture.dispose();
        });
      }
      final data = await t.runAsync(setup.fixture);
      final (state, library, _) = data!;
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final id = library.books.value.first.id;
      library.selectBook(id);
      await t.runAsync(() async {
        for (final book in library.books.value) {
          await library.statistics(book.id);
        }
      });
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          builder: (_, child) => RepaintBoundary(key: captureKey, child: child!),
          theme: deskTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(1440, 960),
              textScaler: TextScaler.linear(1),
            ),
            child: Scaffold(
              body: LibraryPage(library: library, picker: setup.NoPicker()),
            ),
          ),
        ),
      );
      await t.runAsync(() async {
        await library.statistics(id);
      });
      await t.pumpAndSettle();
      expect(find.text('0 卷 · 1 章'), findsWidgets);
      await capture('library-no-volume');
      await t.runAsync(() async {
        final chapters = library.openChapters(id);
        final page = await chapters.read(0);
        await chapters.confirm(
          await chapters.preview(
            page,
            InsertChapterVolume(page.nodes.first.id, '第一卷 测试'),
          ),
        );
        await library.statistics(id);
      });
      await t.pumpAndSettle();
      for (
        var attempt = 0;
        attempt < 100 &&
            find.textContaining('1 卷 · 1 章').evaluate().length != 2;
        attempt++
      ) {
        await t.pump();
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(find.textContaining('1 卷 · 1 章'), findsNWidgets(2));
      await capture('library-volume-edited');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
