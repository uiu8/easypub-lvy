import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/library/library_view_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

import 'library_removal_test.dart' as fixtures;

class _NoPicker extends Fake implements BookFilePicker {}

/// V104：书库收藏夹模式（LIB-283–285）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  Future<void> until(WidgetTester t, bool Function() ready) async {
    for (var i = 0; i < 500; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump(const Duration(milliseconds: 20));
      if (ready()) {
        await t.pump(const Duration(milliseconds: 300));
        return;
      }
    }
    fail('没有等到');
  }

  Future<(PrototypeState, LegacyLibraryAdapter)> pumpLibrary(
    WidgetTester t,
    LibraryViewState view,
  ) async {
    t.view.physicalSize = const Size(1440, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final (state, library, _) = (await t.runAsync(fixtures.fixture))!;
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: LibraryPage(
            library: library,
            picker: _NoPicker(),
            viewState: view,
          ),
        ),
      ),
    );
    await t.pump();
    return (state, library);
  }

  Finder key(String value) => find.byKey(ValueKey(value));
  Finder folder(String name) => find.descendant(
    of: key('library-folder-grid'),
    matching: find.text(name),
  );

  testWidgets('收藏夹模式：顶层是收藏夹与未分类，点进去看书、返回；不出左栏（LIB-283）', (t) async {
    final view = LibraryViewState();
    final (_, library) = await pumpLibrary(t, view);
    final [a, b] = library.books.value;
    final wuxia = library.createCollection('武侠');
    final empty = library.createCollection('待读');
    library.addToCollection(wuxia.id, [a.id]);
    await t.pump();
    expect(key('library-collection-rail'), findsOne);

    await t.tap(key('library-folder-toggle'));
    await t.pump();
    expect(key('library-collection-rail'), findsNothing);
    expect(key('library-folders'), findsOne);
    expect(find.text('2 个收藏夹 · 未分类 1 本'), findsOne);
    expect(folder('武侠'), findsOne);
    expect(folder('待读'), findsOne);
    expect(find.text('1 本 · 不在任何收藏夹'), findsOne);
    // 顶层不列书。
    expect(key('library-row-${a.id}'), findsNothing);
    expect(view.folders, true);

    // 点进“武侠”：只有 a，路径行可返回。
    await t.tap(folder('武侠'));
    await t.pump();
    expect(key('library-folder-crumb'), findsOne);
    expect(key('library-row-${a.id}'), findsOne);
    expect(key('library-row-${b.id}'), findsNothing);
    await t.tap(key('library-folder-back'));
    await t.pump();
    expect(key('library-folders'), findsOne);

    // 未分类：只有 b。
    await t.tap(key('library-folder-unfiled'));
    await t.pump();
    expect(key('library-row-${b.id}'), findsOne);
    expect(key('library-row-${a.id}'), findsNothing);
    await t.tap(key('library-folder-back'));
    await t.pump();

    // 空收藏夹也能点进去，显示“没有匹配的书稿”。
    await t.tap(folder('待读'));
    await t.pump();
    expect(find.text('没有匹配的书稿'), findsOne);
    expect(view.scope, 'c:${empty.id}');

    // 回到平铺：在收藏夹里时保持该收藏夹；左栏回来。
    await t.tap(key('library-folder-toggle'));
    await t.pump();
    expect(key('library-collection-rail'), findsOne);
    expect(view.folders, false);
    expect(view.scope, 'c:${empty.id}');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('一本书在多个收藏夹里各出现一次；收藏夹按名称或书数排列；搜索时直接列书（LIB-284）', (t) async {
    final view = LibraryViewState()..folders = true;
    final (_, library) = await pumpLibrary(t, view);
    final [a, b] = library.books.value;
    final x = library.createCollection('甲');
    final y = library.createCollection('乙');
    library.addToCollection(x.id, [a.id, b.id]);
    library.addToCollection(y.id, [a.id]);
    await t.pump();
    expect(find.text('未分类'), findsOne);
    expect(find.text('2 个收藏夹 · 未分类 0 本'), findsOne);

    List<String> order() => [
      for (final w in t.widgetList<Text>(
        find.descendant(
          of: key('library-folder-grid'),
          matching: find.byType(Text),
        ),
      ))
        if (const {'甲', '乙', '未分类'}.contains(w.data)) w.data!,
    ];
    expect(order(), ['甲', '乙', '未分类']);

    Future<void> pick(String label) async {
      await t.tap(key('library-folder-order'));
      await t.pumpAndSettle();
      await t.tap(find.text(label).last);
      await t.pumpAndSettle();
    }

    await pick('名称');
    // 名称按字符排序（乙 U+4E59 在 甲 U+7532 之前）；未分类总在最后。
    expect(order(), ['乙', '甲', '未分类']);
    await pick('书数（多的在前）');
    expect(order(), ['甲', '乙', '未分类']);
    expect(view.folderOrder, 'count');

    // a 在两个收藏夹里，都能看到。
    await t.tap(folder('乙'));
    await t.pump();
    expect(key('library-row-${a.id}'), findsOne);
    expect(key('library-row-${b.id}'), findsNothing);
    await t.tap(key('library-folder-back'));
    await t.pump();
    await t.tap(folder('甲'));
    await t.pump();
    expect(key('library-row-${a.id}'), findsOne);
    expect(key('library-row-${b.id}'), findsOne);
    await t.tap(key('library-folder-back'));
    await t.pump();

    // 顶层有搜索词时在全部书里搜，直接列书。
    await t.enterText(find.byType(TextField).first, b.title);
    await t.pump();
    expect(key('library-folders'), findsNothing);
    expect(key('library-row-${b.id}'), findsOne);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('收藏夹里拖动勾选的书时，路径行列出其他收藏夹，放上去即加入（LIB-285）', (t) async {
    final view = LibraryViewState()..folders = true;
    final (_, library) = await pumpLibrary(t, view);
    final c = library.createCollection('待读');
    await t.pump();
    final book = library.books.value.last;
    await t.tap(key('library-folder-unfiled'));
    await t.pump();
    library.checkBooks([book.id], true);
    await t.pump();
    expect(key('library-folder-drop-${c.id}'), findsNothing);

    final from = t.getCenter(key('library-row-${book.id}'));
    final gesture = await t.startGesture(from);
    await t.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(from + const Offset(0, -20));
    await t.pump(const Duration(milliseconds: 16));
    // 开始拖动后才出现。
    final chip = key('library-folder-drop-${c.id}');
    expect(chip, findsOne);
    final to = t.getCenter(chip);
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
      await t.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await until(
      t,
      () => find.textContaining('已把 1 本加入“待读”').evaluate().isNotEmpty,
    );
    expect(library.collections.value.single.books, [book.id]);
    expect(chip, findsNothing);
    // 它不再属于未分类。
    expect(key('library-row-${book.id}'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
