import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/catalog_service.dart';
import 'package:easypub_desktop/desk/catalog/source_dialog.dart';

class ReviewCatalog implements CatalogSession {
  int removals = 0;
  Set<int>? requested;
  final entries = List.generate(
    6,
    (i) => CatalogEntry('第${i % 3 + 1}章 标题', '', false),
  );
  @override
  Future<CatalogSnapshot> acquire(
    String source,
    String input, {
    String cookie = '',
    int? declaredTotal,
    bool useCache = true,
  }) async => CatalogSnapshot(
    '测试书',
    '',
    'paste',
    'unknown',
    entries,
    duplicateSegments: const [CatalogDuplicateSegment(0, 3, 3, '第一章', '第三章')],
  );
  @override
  Future<CatalogSnapshot> removeDuplicateSegments(
    CatalogSnapshot candidate,
    Set<int> starts,
  ) async {
    removals++;
    requested = starts;
    return CatalogSnapshot(
      '测试书',
      '',
      'paste',
      'unknown',
      entries.take(3).toList(),
    );
  }

  @override
  void cancel() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('real repeated catalog normalizes only explicit ranges and matches 1834 chapters', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = await Directory.systemTemp.createTemp('catalog-duplicates-');
    final titles = List.generate(1834, (i) => '第${i + 1}章 标题${i + 1}');
    final text = titles.map((t) => '$t\n正文\n').join();
    final file = File('${root.path}/book.txt');
    await file.writeAsString(text);
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    expect((await library.importFiles([file.path])).single.succeeded, true);
    final session = library.openCatalog(library.books.value.single.id);
    final snapshot = await session.acquire(
      'paste',
      [...titles, ...titles.skip(2)].join('\n'),
      declaredTotal: 1834,
    );
    expect(snapshot.entries, hasLength(3666));
    expect(snapshot.duplicateSegments.single.length, 1832);
    final initial = await session.preview(snapshot, identityConfirmed: true);
    expect(initial.unresolved, 1);
    final normalized = await session.removeDuplicateSegments(snapshot, {1834});
    expect(normalized.entries, hasLength(1834));
    expect(snapshot.entries, hasLength(3666));
    expect(normalized.duplicateSegments, isEmpty);
    session.accept(normalized);
    final alignment = await session.preview(
      normalized,
      identityConfirmed: true,
    );
    expect(alignment.matched, 1834);
    expect(alignment.unresolved, 0);
    expect(await File(file.path).readAsString(), text);
    final path = '${root.path}/project.easypub.json';
    expect((await library.saveProject(path)).succeeded, true);
    expect((await library.openProject(path)).succeeded, true);
    final restored = library.openCatalog(library.books.value.single.id);
    expect(restored.saved!.entries, hasLength(1834));
    expect(
      (await restored.preview(
        restored.saved!,
        identityConfirmed: true,
      )).matched,
      1834,
    );
  });

  testWidgets(
    'duplicate dialog requires explicit confirmation and cancel keeps snapshot',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = ReviewCatalog();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => CatalogSourceDialog(
                    session: session,
                    pickFile: () async => null,
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('粘贴目录'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '粘贴目录文本'),
        '第一章 测试',
      );
      await tester.pump();
      await tester.tap(find.text('获取目录'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('核对重复片段'));
      await tester.tap(find.text('核对重复片段'));
      await tester.pumpAndSettle();
      expect(session.removals, 0);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(session.removals, 0);
      await tester.tap(find.text('核对重复片段'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除勾选片段'));
      await tester.pumpAndSettle();
      expect(session.removals, 1);
      expect(session.requested, {3});
      expect(find.text('核对重复片段'), findsNothing);
      expect(find.textContaining('3 条目录'), findsOneWidget);
    },
  );
}
