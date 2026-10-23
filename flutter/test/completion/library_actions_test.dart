import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:go_router/go_router.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/native_conversion_desktop.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/folders/folder_import_dialog.dart';
import 'package:easypub_desktop/desk/folders/favorites_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class Picker extends Fake implements BookFilePicker {
  Picker(this.paths);
  final List<String> paths;
  @override
  Future<List<String>> chooseBooks() async => paths;
}

class BatchingLibrary extends LegacyLibraryAdapter {
  BatchingLibrary({this.hold});
  final Completer<void>? hold;
  final sizes = <int>[];
  final skips = <bool>[];
  bool stopped = false;
  @override
  Future<List<ImportOutcome>> importFiles(
    List<String> paths, {
    bool skipExisting = false,
  }) async {
    sizes.add(paths.length);
    skips.add(skipExisting);
    if (sizes.length == 1 && hold != null) await hold!.future;
    return paths.map((p) => ImportOutcome(p, true, 'ok')).toList();
  }

  @override
  void cancelImport() {
    stopped = true;
  }
}

void main() {
  for (final cancel in [false, true]) {
    testWidgets(
      'file picker batches 129 and cancel stops next batch: $cancel',
      (t) async {
        t.view.physicalSize = const Size(1440, 960);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final gate = cancel ? Completer<void>() : null;
        final library = BatchingLibrary(hold: gate);
        addTearDown(library.dispose);
        await t.pumpWidget(
          MaterialApp(
            theme: deskTheme(),
            home: Scaffold(
              body: LibraryPage(
                library: library,
                picker: Picker(
                  List.generate(129, (i) => 'D:/synthetic/$i.txt'),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('导入').first);
        await t.pump();
        if (cancel) {
          expect(library.sizes, [128]);
          await t.tap(find.text('取消导入'));
          gate!.complete();
        }
        await t.pumpAndSettle();
        expect(library.sizes, cancel ? [128] : [128, 1]);
        expect(library.skips.every((v) => !v), true);
        expect(library.stopped, cancel);
        expect(find.text('导入').first, findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test(
    'KFX output opens through the same literal file path contract',
    () async {
      final dir = await Directory.systemTemp.createTemp('kfx-open-');
      final file = File('${dir.path}/中文 成品.kfx')..writeAsStringSync('fixture');
      final opened = <String>[];
      final desktop = NativeConversionDesktop(
        launchDirectory: (path) async => opened.add(path),
      );
      await desktop.openOutput(file.path);
      expect(opened, [file.absolute.path]);
      await expectLater(
        desktop.openOutput('${dir.path}/missing.kfx'),
        throwsFormatException,
      );
      expect(opened, hasLength(1));
    },
  );
  test(
    'reveal source validates original file and forwards literal path',
    () async {
      final dir = await Directory.systemTemp.createTemp('source-reveal-');
      final file = File('${dir.path}/含 空格 & 中文.txt');
      await file.writeAsString('original');
      final opened = <String>[];
      final desktop = NativeConversionDesktop(
        revealFile: (p) async => opened.add(p),
      );
      await desktop.revealSource(file.path);
      expect(opened, [file.absolute.path]);
      await expectLater(
        desktop.revealSource('relative.txt'),
        throwsFormatException,
      );
      await expectLater(
        desktop.revealSource('${dir.path}/missing.txt'),
        throwsFormatException,
      );
      expect(opened, hasLength(1));
      expect(await file.readAsString(), 'original');
    },
  );
  testWidgets(
    'empty library favorite imports through scan and row menu preserves batch selection',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late LegacyLibraryAdapter library;
      late PrototypeState state;
      late String folder;
      await t.runAsync(() async {
        await (FontLoader('MaterialIcons')..addFont(
              File(
                'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
            ))
            .load();
        await (FontLoader('Microsoft YaHei')..addFont(
              File('C:/Windows/Fonts/msyh.ttc')
                  .readAsBytes()
                  .then((bytes) => bytes.buffer.asByteData()),
            ))
            .load();
        final dir = (await Directory(
          '../artifacts',
        ).createTemp('library-actions-')).absolute;
        folder = (await Directory('${dir.path}/收藏书稿').create()).path;
        await File('$folder/甲.txt').writeAsString('第一章 开始\n甲文\n');
        await File('$folder/乙.txt').writeAsString('第一章 开始\n乙文\n');
        state = PrototypeState(settingsDirectory: '${dir.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        expect(await library.savePatch({'check_after_import': false}), true);
        expect(await library.setFavorite(folder, true), true);
      });
      expect(t.takeException(), isNull);
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      String? revealed;
      final desktop = NativeConversionDesktop(
        revealFile: (p) async => revealed = p,
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: LibraryPage(
                library: library,
                picker: Picker([]),
                onRevealSource: desktop.revealSource,
              ),
            ),
          ),
          GoRoute(
            path: '/books/:id/:page',
            builder: (_, s) => Scaffold(
              body: Text(
                'opened:${s.pathParameters['id']!}:${s.pathParameters['page']!}',
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      final capture = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(),
            routerConfig: router,
          ),
        ),
      );
      Future<void> until(bool Function() condition) async {
        for (var i = 0; i < 300; i++) {
          await t.pump(const Duration(milliseconds: 20));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (condition()) return;
        }
        fail(
          'UI did not finish: ${t.widgetList<Text>(find.byType(Text)).map((w) => w.data).join(' | ')}',
        );
      }

      await t.tap(find.byTooltip('更多导入方式'));
      await t.pumpAndSettle();
      await t.tap(find.text('从收藏文件夹导入'));
      await until(() => find.byType(FavoritesDialog).evaluate().isNotEmpty);
      await until(() => find.text('收藏书稿').evaluate().isNotEmpty);
      await t.tap(find.text('收藏书稿'));
      await t.pump();
      await t.tap(find.text('打开文件夹'));
      await until(() => find.text('导入所选 2 本').evaluate().isNotEmpty);
      expect(find.byType(FolderImportDialog), findsOneWidget);
      await t.pumpAndSettle();
      await t.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${Directory(folder).parent.path}/import-folder.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(library.books.value, isEmpty, reason: 'scan must not auto-import');
      await t.tap(find.text('导入所选 2 本'));
      await until(
        () => library.books.value.length == 2 && !library.importing.value,
      );
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: find.byType(FolderImportDialog),
          matching: find.widgetWithText(TextButton, '关闭'),
        ),
      );
      await t.pumpAndSettle();
      final book = library.books.value.first;
      final other = library.books.value.last;
      library.checkBooks([other.id], true);
      library.selectBook(other.id);
      await t.pump();
      await t.tap(find.byTooltip('书籍操作：${book.title}'));
      await t.pumpAndSettle();
      await t.tap(find.text('在资源管理器中显示原文件'));
      await until(() => revealed != null);
      expect(revealed, File(book.path).absolute.path);
      expect(library.selection.value.current, other.id);
      expect(library.selection.value.selected, {other.id});
      await t.tap(find.byTooltip('书籍操作：${book.title}'));
      await t.pumpAndSettle();
      // R1 起书籍操作菜单是编辑台菜单，在打开的面板里找条目。
      await t.tap(
        find.descendant(
          of: find.byKey(deskMenuPanelKey),
          matching: find.text('文本清理'),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('opened:${book.id}:cleanup'), findsOneWidget);
      expect(library.selection.value.current, book.id);
      expect(library.selection.value.selected, {other.id});
      router.go('/');
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('更多导入方式'));
      await t.pumpAndSettle();
      expect(find.text('从收藏文件夹导入'), findsOneWidget);
      expect(find.text('导入文件夹'), findsOneWidget);
      expect(find.text('导入文件'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
