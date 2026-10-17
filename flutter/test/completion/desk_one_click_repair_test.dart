import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/catalog/catalog_page.dart';
import 'package:easypub_desktop/desk/catalog/composition_dialog.dart';
import 'package:easypub_desktop/desk/catalog/quick_identity_dialog.dart';
import 'package:easypub_desktop/desk/catalog/source_dialog.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/checks/checks_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

/// 一键修复入口（CH-243–246）：检查页、章节页按钮进入全书自动方案；
/// 一键目录修复必须经身份核对与组合预览确认后才改书稿。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  Future<(PrototypeState, LegacyLibraryAdapter, String)> setup(
    WidgetTester t,
    String prefix, {
    bool catalog = true,
  }) async {
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final path = (await Directory('../artifacts').createTemp(prefix))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$path/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      await File(
        '$path/book.txt',
      ).writeAsString('第一章 甲\n甲文\n第二章 乙\n乙文\n第三章 丙\n丙文\n');
      expect(
        (await library.importFiles(['$path/book.txt'])).single.succeeded,
        true,
      );
      id = state.currentId;
      if (catalog) {
        final session = library.openCatalog(id);
        final snapshot = await session.acquire(
          'paste',
          '第一卷 起\n第一章 甲\n第二章 乙\n第二卷 终\n第三章 丙',
          declaredTotal: 3,
        );
        session.accept(snapshot);
        final plan = await session.preview(snapshot, identityConfirmed: true);
        expect(plan.changes, isNotEmpty, reason: '测试书需要有推荐的目录修改');
        session.cancel();
      }
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    return (state, library, id);
  }

  Future<void> until(WidgetTester t, bool Function() ready) async {
    for (var i = 0; i < 300; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (ready()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    fail('界面未就绪');
  }

  void size(WidgetTester t, Size s) {
    t.view.physicalSize = s;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  testWidgets('一键目录修复：身份核对 → 对齐 → 组合预览确认后才改书稿', (t) async {
    size(t, const Size(1600, 1100));
    final (_, library, id) = await setup(t, 'one-click-catalog-');
    late List<String> before;
    await t.runAsync(() async {
      before = (await library.openChapters(id).read(0)).nodes
          .map((n) => n.title)
          .toList();
    });
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: CatalogPage(
            library: library,
            bookId: id,
            quick: true,
            onReturn: () {},
            pickFile: () async => null,
          ),
        ),
      ),
    );
    await until(
      t,
      () => find.byType(CatalogQuickIdentityDialog).evaluate().isNotEmpty,
    );
    expect(find.text('本书已保存的目录快照'), findsOneWidget);
    final next = find.byKey(const ValueKey('catalog-quick-continue'));
    expect(t.widget<DeskButton>(next).onPressed, isNull);
    await t.tap(find.byKey(const ValueKey('catalog-quick-identity')));
    await t.pump();
    expect(t.widget<DeskButton>(next).onPressed, isNotNull);
    await t.tap(next);
    await until(
      t,
      () => find.byType(CatalogCompositionDialog).evaluate().isNotEmpty,
    );
    await until(
      t,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    // 组合预览打开时书稿未改。
    await t.runAsync(() async {
      expect(
        (await library.openChapters(id).read(0)).nodes.map((n) => n.title),
        before,
      );
    });
    await t.pumpAndSettle();
    await t.tap(find.text('已核对所选修改和预览'));
    await t.pump();
    await t.tap(find.text('确认应用目录修复'));
    await until(
      t,
      () => find.byType(CatalogCompositionDialog).evaluate().isEmpty,
    );
    await until(
      t,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    await t.runAsync(() async {
      final after = (await library.openChapters(id).read(0)).nodes
          .map((n) => n.title)
          .toList();
      expect(after, isNot(before));
      expect(after, containsAll(['第一卷 起', '第二卷 终']));
    });
    expect(find.text('撤销本次目录修复'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('一键目录修复：没有目录时先打开获取弹窗，取消后停在本页且不改书稿', (t) async {
    size(t, const Size(1600, 1100));
    final (_, library, id) = await setup(
      t,
      'one-click-catalog-empty-',
      catalog: false,
    );
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: CatalogPage(
            library: library,
            bookId: id,
            quick: true,
            onReturn: () {},
            pickFile: () async => null,
          ),
        ),
      ),
    );
    await until(t, () => find.byType(CatalogSourceDialog).evaluate().isNotEmpty);
    await t.tap(find.text('取消'));
    await until(t, () => find.byType(CatalogSourceDialog).evaluate().isEmpty);
    await t.pumpAndSettle();
    expect(find.byType(CatalogQuickIdentityDialog), findsNothing);
    expect(find.text('读取后核对书名、作者和章节目录'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('检查页与章节页的“一键修复…”进入全书自动方案', (t) async {
    size(t, const Size(1440, 900));
    final (_, library, id) = await setup(
      t,
      'one-click-entry-',
      catalog: false,
    );
    final calls = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: BookChecksPage(
            library: library,
            bookId: id,
            onRepair: (guided) => calls.add(guided ? 'guided' : 'auto'),
            onCatalog: () => calls.add('catalog'),
            onCatalogRepair: () => calls.add('catalog-quick'),
            onChapter: (_) {},
            onCleanup: () {},
          ),
        ),
      ),
    );
    await until(
      t,
      () =>
          find.byKey(const ValueKey('checks-auto-repair')).evaluate().isNotEmpty,
    );
    await until(
      t,
      () =>
          t
              .widget<DeskButton>(
                find.byKey(const ValueKey('checks-auto-repair')),
              )
              .onPressed !=
          null,
    );
    await t.tap(find.byKey(const ValueKey('checks-auto-repair')));
    // V14：目录修复合并进“一键修复 ▾”的下拉菜单。
    await t.tap(find.byKey(const ValueKey('checks-repair-menu')));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    await t.tap(find.byKey(const ValueKey('checks-catalog-repair')));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(calls, ['auto', 'catalog-quick']);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    calls.clear();
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChapterWorkspace(
            library: library,
            bookId: id,
            onRepair: (guided) => calls.add(guided ? 'guided' : 'auto'),
            onCatalog: () => calls.add('catalog'),
            onCatalogRepair: () => calls.add('catalog-quick'),
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('chapter-auto-repair'));
    await until(t, () => button.evaluate().isNotEmpty);
    await until(
      t,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    await t.tap(button);
    expect(calls, ['auto']);
    // “更多 → 检查与修复”：一键修复、一键目录修复、逐项处理问题。
    Future<void> menu(String label) async {
      await t.tap(find.text('更多'));
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: find.byWidgetPredicate((w) => w is PopupMenuItem<String>),
          matching: find.text(label),
        ),
      );
      await t.pumpAndSettle();
    }

    await menu('一键目录修复…');
    await menu('逐项处理问题');
    expect(calls, ['auto', 'catalog-quick', 'guided']);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(t.takeException(), isNull);
  });
}
