import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/output_history_service.dart';
import 'package:easypub_desktop/application/source_refresh_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/conversion/output_history_page.dart';
import 'package:easypub_desktop/desk/conversion/output_reveal.dart';
import 'package:easypub_desktop/desk/library/book_summary_panel.dart';

/// V18：输出记录对应书库中的书（OUT-076/077），书库详情“最近输出”（LIB-113）。真实 Rust。
class _Desktop implements ConversionDesktop, BookSourceDesktop {
  final calls = <String>[];
  @override
  Future<void> revealSource(String path) async => calls.add('select $path');
  @override
  Future<void> openDirectory(String path) async => calls.add('open $path');
  @override
  Future<void> openOutput(String path) async => calls.add('output $path');
  @override
  Future<String?> bundledConverter() async => null;
  @override
  Future<String?> chooseConverter() async => null;
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  Future<(PrototypeState, LegacyLibraryAdapter, String, List<String>)> open(
    String prefix,
  ) async {
    final root = (await Directory('../artifacts').createTemp(prefix))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    await library.load();
    await library.savePatch({'check_after_import': false});
    final ids = <String>[];
    for (final name in ['甲书', '乙书']) {
      final file = File('$root/$name.txt')
        ..writeAsStringSync('第一章 开始\n$name正文\n第二章 后续\n后文\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      ids.add(state.currentId);
    }
    return (state, library, root, ids);
  }

  Future<void> convert(
    LegacyLibraryAdapter library,
    String root,
    String id,
  ) async {
    final conversion = library.openConversion();
    try {
      final plan = await conversion.preview(
        ConversionRequest(
          books: [id],
          directory: root,
          format: 'EPUB',
          runChecks: false,
        ),
      );
      final output = (await conversion.commit(
        plan,
        acknowledgeWarnings: true,
      )).single;
      expect(output.phase, 'complete', reason: output.detail);
    } finally {
      conversion.dispose();
    }
  }

  test('输出记录对应书库中的书：同一原稿、旧版原稿、书库中没有（OUT-076/077，LIB-113）', () async {
    final (state, library, root, ids) = await open('v18-match-');
    try {
      await convert(library, root, ids[0]);
      final history = library.openOutputHistory();
      final recent = history.recentForBook(ids[0]);
      expect(recent, hasLength(1));
      expect(recent.single.bookId, ids[0]);
      expect(recent.single.bookTitle, '甲书');
      expect(recent.single.bookMatch, OutputBookMatch.current);
      expect(recent.single.format, 'EPUB');
      expect(history.recentForBook(ids[1]), isEmpty);

      // 记录保存在设置目录，书的标识随记录保存：新会话读取后，书库里还没有这本书时
      // 如实标为无法对应；打开另存的项目、书回到书库后又能对应。
      await state.outputs.historySaved;
      expect(
        (await library.saveProject('$root/v18.easypub.json')).succeeded,
        true,
      );
      final reopened = PrototypeState(settingsDirectory: '$root/settings');
      final again = LegacyLibraryAdapter(backend: reopened);
      try {
        await again.load();
        final restored = again.openOutputHistory();
        await restored.load();
        expect(restored.count, 1);
        expect(restored.page(0).single.bookId, ids[0]);
        expect(restored.page(0).single.bookMatch, OutputBookMatch.missing);
        expect(
          (await again.openProject('$root/v18.easypub.json')).succeeded,
          true,
        );
        final record = restored.recentForBook(ids[0]).single;
        expect(record.bookMatch, OutputBookMatch.current);
        expect(record.bookTitle, '甲书');
      } finally {
        again.dispose();
        reopened.dispose();
      }

      // 原稿内容变化后重新导入同一路径：成品来自旧版原稿。
      File('$root/甲书.txt').writeAsStringSync('第一章 开始\n改过的正文\n第二章 后续\n后文\n');
      // 再导入同一路径会被当作已在书库而跳过；原稿变化走“原稿刷新”替换正文。
      final refresh = library as SourceRefreshService;
      final preview = await refresh.previewSourceRefresh(ids[0]);
      expect(preview.bodyChanged, true);
      await refresh.applySourceRefresh(
        preview,
        fields: const {},
        replaceBody: true,
      );
      expect(state.shelf.books.any((b) => b.id == ids[0]), true);
      final older = history.recentForBook(ids[0]).single;
      expect(older.bookMatch, OutputBookMatch.olderSource);

      // 移出书库：记录如实标为无法对应，“最近输出”不再列出。
      library.removeBooks({ids[0]});
      final missing = history.find(older.id)!;
      expect(missing.bookMatch, OutputBookMatch.missing);
      expect(missing.bookTitle, '');
      expect(history.recentForBook(ids[0]), isEmpty);
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  test('打开输出文件夹：成品还在时选中成品，不在时打开输出文件夹（LIB-113）', () async {
    final dir = await Directory.systemTemp.createTemp('v18-reveal-');
    final file = File('${dir.path}/成品.epub')..writeAsStringSync('x');
    OutputRecord record(String path) => OutputRecord(
      id: 't',
      title: '甲书',
      format: 'EPUB',
      path: path,
      directory: dir.path,
      status: '已完成',
      detail: '',
      verification: '',
      startedAt: DateTime(2026, 10, 13),
      restored: true,
      busy: false,
      terminal: true,
      interrupted: false,
    );
    final desktop = _Desktop();
    await revealOutput(desktop, record(file.path));
    await revealOutput(desktop, record('${dir.path}/已删除.epub'));
    expect(desktop.calls, ['select ${file.path}', 'open ${dir.path}']);
    await dir.delete(recursive: true);
  });

  testWidgets('书库详情“最近输出”与转换历史“书库中的书”（LIB-113，OUT-076）', (t) async {
    t.view.physicalSize = const Size(1400, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late List<String> ids;
    late OutputHistoryService history;
    await t.runAsync(() async {
      final opened = await open('v18-ui-');
      (state, library, _, ids) = (opened.$1, opened.$2, opened.$3, opened.$4);
      await convert(library, opened.$3, ids[0]);
      history = library.openOutputHistory();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final revealed = <OutputRecord>[];
    var historyOpened = 0;
    String? bookId = ids[0];
    late StateSetter rebuild;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              final book = library.books.value.firstWhere(
                (b) => b.id == bookId,
              );
              return Row(
                children: [
                  SizedBox(
                    width: 320,
                    child: BookSummaryPanel(
                      key: ValueKey(book.id),
                      library: library,
                      book: book,
                      open: (_) {},
                      outputs: history,
                      onRevealOutput: (record) async => revealed.add(record),
                      onOutputHistory: () => historyOpened++,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final record = history.recentForBook(ids[0]).single;
    expect(find.text('最近输出'), findsOneWidget);
    final row = find.byKey(ValueKey('book-summary-output-${record.id}'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('EPUB')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('已完成')),
      findsOneWidget,
    );
    await t.ensureVisible(row);
    await t.tap(
      find.byKey(ValueKey('book-summary-output-reveal-${record.id}')),
    );
    await t.tap(find.text('全部记录 →'));
    await t.pump();
    expect(revealed.single.id, record.id);
    expect(historyOpened, 1);
    // 没有输出过的书。
    rebuild(() => bookId = ids[1]);
    await t.pumpAndSettle();
    expect(find.text('还没有输出过。'), findsOneWidget);

    // 转换历史：对应得上时写书名并可在书库中查看；移出书库后如实写无法对应。
    final opened = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: OutputHistoryPage(
            history: history,
            desktop: _Desktop(),
            onBack: () {},
            onOpenBook: opened.add,
          ),
        ),
      ),
    );
    for (var i = 0; i < 100; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump(const Duration(milliseconds: 20));
      if (find
          .byKey(const ValueKey('output-history-book'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    await t.pumpAndSettle();
    expect(find.text('书库中的书'), findsOneWidget);
    expect(find.text('甲书'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('output-history-open-book')));
    expect(opened, [ids[0]]);
    expect(
      find.byKey(ValueKey('output-history-unmatched-${record.id}')),
      findsNothing,
    );
    library.removeBooks({ids[0]});
    await t.pumpAndSettle();
    expect(
      find.byKey(ValueKey('output-history-unmatched-${record.id}')),
      findsOneWidget,
    );
    expect(find.text('无法对应：书库中没有这本书（可能已移出书库，或原稿换了位置）。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('output-history-open-book')),
      findsNothing,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
