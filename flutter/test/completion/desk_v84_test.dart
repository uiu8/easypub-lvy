import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/folders/folder_book_tools.dart';
import 'package:easypub_desktop/desk/folders/folder_import_dialog.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

import 'library_removal_test.dart' as fixtures;

class _NoPicker extends Fake implements BookFilePicker {}

const _template = {
  'category': {'op': 'set', 'value': '武侠'},
  'author': {'op': 'fill_empty', 'value': '佚名'},
};

/// V84：文件夹导入的勾选按钮、拖动选书与排序（FOLD-083–087）；书库收藏夹与批量设类别（LIB-118–127）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('排序与类型筛选只改显示顺序（FOLD-085）', () {
    final books = [
      FolderBook('D:/b.txt', 30, false, modified: DateTime(2026, 1, 2)),
      FolderBook('D:/a.epub', 10, false, modified: DateTime(2026, 1, 3)),
      FolderBook('D:/c.txt', 20, true, modified: DateTime(2026, 1, 1)),
    ];
    final view = FolderListView();
    String names() => view.apply(books).map((b) => b.name).join(',');
    expect(names(), 'a.epub,b.txt,c.txt');
    view.sortBy(FolderSort.size); // 大小默认从大到小
    expect(names(), 'b.txt,c.txt,a.epub');
    view.sortBy(FolderSort.size);
    expect(names(), 'a.epub,c.txt,b.txt');
    view.sortBy(FolderSort.modified); // 最新在前
    expect(names(), 'a.epub,b.txt,c.txt');
    view.sortBy(FolderSort.type);
    expect(names(), 'a.epub,b.txt,c.txt');
    view.type = 'TXT';
    expect(names(), 'b.txt,c.txt');
  });

  test('收藏夹：加入、预设预览与应用、整批撤销、随项目保存（LIB-118–124）', () async {
    final (state, library, root) = await fixtures.fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final ids = library.books.value.map((b) => b.id).toList();
    final c = library.createCollection(
      '武侠',
      template: _template,
      autoApply: true,
    );
    expect(
      () => library.createCollection(' 武侠 '),
      throwsA(isA<FormatException>()),
    );
    expect(library.addToCollection(c.id, ids), ids);
    expect(library.addToCollection(c.id, ids), isEmpty);
    // 加入只改分组，不改书籍信息。
    expect(state.production.settings(ids.first)['category'], '');

    final preview = await library.previewFields(c.template, ids);
    expect(preview.changedBooks, 2);
    expect(preview.items.first.changed, containsAll(['category', 'author']));
    final applied = await library.applyFields(preview);
    expect(applied.books, hasLength(2));
    for (final id in ids) {
      expect(state.production.settings(id)['category'], '武侠');
      expect(state.production.settings(id)['author'], '佚名');
    }
    expect(library.books.value.every((b) => b.category == '武侠'), true);
    expect(library.knownCategories(), ['武侠']);
    // 一次预览只能应用一次。
    await expectLater(
      library.applyFields(preview),
      throwsA(isA<FormatException>()),
    );
    expect(await library.undoFields(applied), contains('已撤销 2 本'));
    for (final id in ids) {
      expect(state.production.settings(id)['category'], '');
    }

    library.removeFromCollection(c.id, [ids.last]);
    expect(library.collections.value.single.books, [ids.first]);
    expect(library.bookIdForPath(library.books.value.first.path), ids.first);

    final project = '$root/collections.easypub.json';
    expect((await library.saveProject(project)).succeeded, true);
    library.deleteCollection(c.id);
    expect(library.collections.value, isEmpty);
    expect((await library.openProject(project)).succeeded, true);
    final reopened = library.collections.value.single;
    expect(reopened.name, '武侠');
    expect(reopened.autoApply, true);
    expect(reopened.template['category'], {'op': 'set', 'value': '武侠'});
    expect(reopened.books, [ids.first]);
  });

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

  Future<(PrototypeState, LegacyLibraryAdapter, String)> pumpLibrary(
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1440, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final data = (await t.runAsync(fixtures.fixture))!;
    final (state, library, _) = data;
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: LibraryPage(library: library, picker: _NoPicker()),
        ),
      ),
    );
    await t.pump();
    return data;
  }

  testWidgets('书库左栏：勾选后加入收藏夹、按预设自动套用并可撤销、按收藏夹显示（LIB-118–123）', (t) async {
    final (state, library, _) = await pumpLibrary(t);
    expect(find.byKey(const ValueKey('library-collection-rail')), findsOne);
    expect(find.byKey(const ValueKey('library-scope-all')), findsOne);
    final c = library.createCollection(
      '武侠',
      template: _template,
      autoApply: true,
    );
    await t.pump();
    final row = find.byKey(ValueKey('library-collection-${c.id}'));
    expect(row, findsOne);

    await t.tap(find.byTooltip('全选筛选结果'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('library-collect-selected')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey('collection-pick-${c.id}')));
    await until(t, () => find.textContaining('已更新 2 本').evaluate().isNotEmpty);
    expect(library.collections.value.single.books, hasLength(2));
    expect(library.books.value.every((b) => b.category == '武侠'), true);
    // 左栏出现“类别”一节。
    expect(find.byKey(const ValueKey('library-scope-category-武侠')), findsOne);

    await t.tap(find.text('撤销'));
    await until(t, () => find.textContaining('已撤销 2 本').evaluate().isNotEmpty);
    expect(library.books.value.every((b) => b.category.isEmpty), true);

    // 只看这个收藏夹；移出一本后只剩一本。
    await t.tap(row);
    await t.pump();
    final first = library.books.value.first;
    library.checkBooks(library.books.value.map((b) => b.id), false);
    library.checkBooks([first.id], true);
    await t.pump();
    await t.tap(find.byKey(const ValueKey('library-uncollect-selected')));
    await t.pump();
    expect(library.collections.value.single.books, isNot(contains(first.id)));
    expect(find.byKey(ValueKey('library-row-${first.id}')), findsNothing);
    expect(state.collections.single['books'], hasLength(1));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('把勾选的书拖到收藏夹上加入；预设先预览再应用（LIB-121）', (t) async {
    final (_, library, _) = await pumpLibrary(t);
    final c = library.createCollection('待读', template: _template);
    await t.pump();
    final book = library.books.value.last;
    library.checkBooks([book.id], true);
    await t.pump();
    final from = t.getCenter(find.byKey(ValueKey('library-row-${book.id}')));
    final to = t.getCenter(find.byKey(ValueKey('library-collection-${c.id}')));
    final gesture = await t.startGesture(from);
    await t.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
      await t.pump(const Duration(milliseconds: 16));
    }
    // 拖动的是书，不是选框。
    expect(find.byKey(const ValueKey('drag-select-band')), findsNothing);
    await gesture.up();
    await until(
      t,
      () => find
          .byKey(const ValueKey('field-preview-apply'))
          .evaluate()
          .isNotEmpty,
    );
    expect(library.collections.value.single.books, [book.id]);
    expect(find.textContaining('类别：（空） → 武侠'), findsOne);
    await t.tap(find.byKey(const ValueKey('field-preview-apply')));
    await until(t, () => find.textContaining('已更新 1 本').evaluate().isNotEmpty);
    expect(
      library.books.value.firstWhere((b) => b.id == book.id).category,
      '武侠',
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('左栏可拖动伸缩、可收成图标条；普通窗口也有；更窄时筛选收成菜单（LIB-118、LIB-128）', (t) async {
    final (_, library, _) = await pumpLibrary(t);
    final c = library.createCollection('武侠');
    final rail = find.byKey(const ValueKey('library-collection-rail'));
    final strip = find.byKey(const ValueKey('library-collection-strip'));
    final handle = find.byKey(const ValueKey('library-rail-handle'));
    double railWidth() =>
        t.getSize(find.byKey(const ValueKey('library-rail'))).width;
    Future<void> resize(double width) async {
      t.view.physicalSize = Size(width, 800);
      await t.pumpAndSettle();
    }

    // 1000 宽：左栏在，筛选完整一行，详情栏让位。
    await resize(1000);
    expect(rail, findsOne);
    expect(find.byKey(const ValueKey('library-detail-column')), findsNothing);
    expect(find.text('仅看已勾选'), findsOne);
    // 拖右边缘：宽度跟着走（184 → 244），松手后保留。
    final before = railWidth();
    await t.drag(handle, const Offset(60, 0));
    await t.pumpAndSettle();
    expect(railWidth(), closeTo(before + 60, 1));
    // 拖到最窄以下：整栏收起（V94），显示范围改用筛选行的下拉。
    await t.drag(handle, const Offset(-200, 0));
    await t.pumpAndSettle();
    expect(rail, findsNothing);
    expect(strip, findsNothing);
    expect(find.byKey(const ValueKey('library-rail')), findsNothing);
    // 标题行的开关展开，回到上次的宽度；再点收起、再点展开。
    await t.tap(find.byKey(const ValueKey('library-rail-toggle')));
    await t.pumpAndSettle();
    expect(rail, findsOne);
    await t.tap(find.byKey(const ValueKey('library-rail-toggle')));
    await t.pumpAndSettle();
    expect(rail, findsNothing);
    await t.tap(find.byKey(const ValueKey('library-rail-toggle')));
    await t.pumpAndSettle();
    expect(rail, findsOne);
    expect(railWidth(), closeTo(before + 60, 1));
    await t.drag(handle, const Offset(-60, 0));
    await t.pumpAndSettle();

    // 1400 宽：左栏、书架、详情栏三栏都在。
    await resize(1400);
    expect(rail, findsOne);
    expect(find.byKey(const ValueKey('library-detail-column')), findsOne);

    // 780 宽：左栏仍在，格式、状态、仅看已勾选收进“筛选”菜单。
    await resize(780);
    expect(rail, findsOne);
    expect(find.text('仅看已勾选'), findsNothing);
    await t.tap(find.byKey(const ValueKey('library-filter-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('待处理').last);
    await t.pumpAndSettle();
    expect(find.byTooltip('筛选：待处理'), findsOne);

    // 600 宽：只显示图标条，开关不可用；收藏夹仍在、可点。
    await resize(600);
    expect(strip, findsOne);
    expect(rail, findsNothing);
    await t.tap(find.byKey(ValueKey('library-collection-${c.id}')));
    await t.pumpAndSettle();
    expect(find.text('0 / 2 本'), findsOne);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('书库排序：按书名升降序（LIB-127）', (t) async {
    final (_, library, _) = await pumpLibrary(t);
    Offset at(String title) => t.getTopLeft(
      find.byKey(
        ValueKey(
          'library-row-${library.books.value.firstWhere((b) => b.title == title).id}',
        ),
      ),
    );
    // 书架按行排列：先比行，再比列。
    bool before(String a, String b) =>
        at(a).dy < at(b).dy || (at(a).dy == at(b).dy && at(a).dx < at(b).dx);
    await t.tap(find.byKey(const ValueKey('library-sort')));
    await t.pumpAndSettle();
    await t.tap(find.text('书名').last);
    await t.pumpAndSettle();
    // 书名按 Unicode 码位比较（不是拼音序）：“乙”(U+4E59) 在“甲”(U+7532) 前。
    expect(before('乙', '甲'), true);
    await t.tap(find.byKey(const ValueKey('library-sort')));
    await t.pumpAndSettle();
    await t.tap(find.text('书名').last);
    await t.pumpAndSettle();
    expect(before('甲', '乙'), true);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('导入文件夹：全选 / 取消全选 / 反选、拖动连选、排序与导入后加入收藏夹（FOLD-083–087）', (t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final (state, library, root) = (await t.runAsync(fixtures.fixture))!;
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final input = '$root/scan';
    await t.runAsync(() async {
      await Directory(input).create();
      var i = 0;
      for (final name in ['丙', '丁', '戊']) {
        final file = File('$input/$name.txt');
        await file.writeAsString('第一章 开始\n$name${'正文' * (i + 1) * 40}\n');
        await file.setLastModified(DateTime(2026, 1, 1 + i));
        i++;
      }
    });
    final c = library.createCollection('新书');
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: FolderImportDialog(
            library: library,
            picker: _NoPicker(),
            initialPath: input,
          ),
        ),
      ),
    );
    await until(t, () => find.text('导入所选 3 本').evaluate().isNotEmpty);
    expect(find.text('2026-01-03 00:00'), findsOne);

    await t.tap(find.byKey(const ValueKey('folder-select-none')));
    await t.pump();
    expect(find.text('导入所选 0 本'), findsOne);
    await t.tap(find.byKey(const ValueKey('folder-select-all')));
    await t.pump();
    expect(find.text('导入所选 3 本'), findsOne);
    await t.tap(find.byKey(const ValueKey('folder-select-invert')));
    await t.pump();
    expect(find.text('导入所选 0 本'), findsOne);

    // 按大小排序：最大的“戊”排第一。
    await t.tap(find.byKey(const ValueKey('folder-sort')));
    await t.pumpAndSettle();
    await t.tap(find.text('按大小').last);
    await t.pumpAndSettle();
    final names = find.descendant(
      of: find.byKey(const ValueKey('folder-import-drag-select')),
      matching: find.textContaining('.txt'),
    );
    expect((names.evaluate().first.widget as Text).data, '戊.txt');

    // 在勾选列从第一行拖到第二行：连续勾选两本。
    final region = find.byKey(const ValueKey('folder-import-drag-select'));
    final topLeft = t.getTopLeft(region);
    final gesture = await t.startGesture(
      topLeft + const Offset(20, 21),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    for (var y = 21.0; y <= 63; y += 7) {
      await gesture.moveTo(topLeft + Offset(20, y));
      await t.pump();
    }
    await gesture.up();
    await t.pump();
    expect(find.text('导入所选 2 本'), findsOne);

    await t.tap(find.byKey(const ValueKey('folder-import-collection')));
    await t.pumpAndSettle();
    await t.tap(find.text('新书').last);
    await t.pumpAndSettle();
    await t.tap(find.text('导入所选 2 本'));
    await until(t, () => library.collections.value.single.books.length == 2);
    final members = library.collections.value.single.books;
    expect(
      library.books.value
          .where((b) => members.contains(b.id))
          .map((b) => b.title)
          .toSet(),
      {'戊', '丁'},
    );
    expect(c.id, library.collections.value.single.id);
    await t.pumpWidget(const SizedBox());
  });
}
