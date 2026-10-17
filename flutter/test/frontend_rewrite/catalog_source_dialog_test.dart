import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/catalog_service.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/catalog/source_dialog.dart';

class _Catalog implements CatalogSession {
  @override
  Future<List<CatalogSearchResult>> search(
    String query, {
    String cookie = '',
  }) => throw StateError('search not used in fixture');
  @override
  Future<CatalogSnapshot> removeDuplicateSegments(
    CatalogSnapshot candidate,
    Set<int> starts,
  ) => throw StateError('no duplicates in fixture');
  @override
  Future<CatalogRepairDraft> prepareRepair(
    CatalogAlignment alignment, {
    Set<String>? selectedIds,
  }) => throw StateError('source dialog must not prepare repairs');
  @override
  Future<ChapterPage> composition(
    CatalogAlignment alignment,
    int offset, {
    required bool withCatalog,
    String? nodeId,
    int bodyOffset = 0,
  }) => throw StateError('source dialog must not compose');
  @override
  Future<String> evidence(
    CatalogAlignment alignment,
    CatalogAlignmentRow row,
  ) => throw StateError('source dialog must not read source evidence');
  @override
  Future<CatalogAlignment> choose(
    CatalogAlignment previous,
    int line,
    String? entryId,
  ) => throw UnimplementedError();
  @override
  Future<CatalogAlignment> preview(
    CatalogSnapshot snapshot, {
    required bool identityConfirmed,
    bool reorder = false,
  }) => throw StateError('source dialog must not align');
  final reply = Completer<CatalogSnapshot>();
  int cancelled = 0;
  @override
  Future<CatalogSnapshot> acquire(
    String source,
    String input, {
    String cookie = '',
    int? declaredTotal,
    bool useCache = true,
  }) => reply.future;
  @override
  void cancel() {
    cancelled++;
  }

  @override
  CatalogSnapshot? get saved => null;
  @override
  void accept(CatalogSnapshot candidate) =>
      throw StateError('dialog must not persist');
}

void main() {
  testWidgets('closing source while pending discards late result', (
    tester,
  ) async {
    final session = _Catalog();
    CatalogSnapshot? adopted;
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('打开'),
              onPressed: () async {
                adopted = await showDialog<CatalogSnapshot>(
                  context: context,
                  builder: (_) => CatalogSourceDialog(
                    session: session,
                    pickFile: () async => null,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '书名或起点书籍链接'),
      'https://www.qidian.com/book/123/',
    );
    await tester.pump();
    await tester.tap(find.text('获取目录'));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(session.cancelled, 1);
    session.reply.complete(
      const CatalogSnapshot('迟到目录', '作者', 'paste', 'unknown', []),
    );
    await tester.pumpAndSettle();
    expect(adopted, isNull);
    expect(find.textContaining('迟到目录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing source invalidates acquired preview', (tester) async {
    final session = _Catalog();
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: CatalogSourceDialog(
            session: session,
            pickFile: () async => 'D:/目录.txt',
          ),
        ),
      ),
    );
    await tester.tap(find.text('本地目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择目录文件…'));
    await tester.pumpAndSettle();
    expect(find.text('D:/目录.txt'), findsOneWidget);
    await tester.tap(find.text('获取目录'));
    await tester.pump();
    session.reply.complete(
      const CatalogSnapshot('甲', '乙', 'local', 'unknown', []),
    );
    await tester.pumpAndSettle();
    TextButton preview() =>
        tester.widget<TextButton>(find.widgetWithText(TextButton, '预览目录'));
    expect(preview().onPressed, isNotNull);
    await tester.enterText(
      find.widgetWithText(TextField, '本地目录文件'),
      'D:/另一本.txt',
    );
    await tester.pump();
    expect(preview().onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
