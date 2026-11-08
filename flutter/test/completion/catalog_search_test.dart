import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/infrastructure/legacy_catalog_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/catalog_service.dart';
import 'package:easypub_desktop/desk/catalog/source_dialog.dart';

class SearchCatalog implements CatalogSession {
  String? searched, searchCookie, acquired, acquireCookie;
  bool? cache;
  @override
  Future<List<CatalogSearchResult>> search(
    String query, {
    String cookie = '',
  }) async {
    searched = query;
    searchCookie = cookie;
    return const [
      CatalogSearchResult('123', '测试小说结果', 'https://www.qidian.com/book/123/'),
    ];
  }

  @override
  Future<CatalogSnapshot> acquire(
    String source,
    String input, {
    String cookie = '',
    int? declaredTotal,
    bool useCache = true,
  }) async {
    acquired = input;
    acquireCookie = cookie;
    cache = useCache;
    return const CatalogSnapshot('测试小说结果', '', 'online', 'complete', [
      CatalogEntry('第一章', '', false),
    ]);
  }

  @override
  CatalogSnapshot? get saved => null;
  @override
  void cancel() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('book name is a search action rather than a catalog URL', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CatalogSourceDialog(
            session: SearchCatalog(),
            pickFile: () async => null,
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, '测试小说');
    await tester.pump();
    expect(find.text('搜索书名'), findsOneWidget);
  });
  testWidgets(
    'search result selection keeps credential and honors forced refresh',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SearchCatalog();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogSourceDialog(
              session: session,
              pickFile: () async => null,
            ),
          ),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, '书名或起点书籍链接'),
        '测试小说',
      );
      await tester.pump();
      await tester.tap(find.text('优先使用缓存'));
      await tester.tap(find.text('访问设置'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '当前窗口 Cookie（可选）'),
        'session=fixture',
      );
      await tester.ensureVisible(find.text('搜索书名'));
      await tester.tap(find.text('搜索书名'));
      await tester.pumpAndSettle();
      expect(session.searched, '测试小说');
      expect(session.searchCookie, 'session=fixture');
      await tester.ensureVisible(find.text('测试小说结果'));
      await tester.tap(find.text('测试小说结果'));
      await tester.pumpAndSettle();
      expect(session.acquired, 'https://www.qidian.com/book/123/');
      expect(session.acquireCookie, 'session=fixture');
      expect(session.cache, false);
      expect(find.textContaining('1 条目录'), findsOneWidget);
    },
  );

  test(
    'adapter sends search/refresh contract and rejects cancelled late search',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = await Directory.systemTemp.createTemp(
        'catalog-search-contract-',
      );
      final state = PrototypeState(settingsDirectory: '${root.path}/settings');
      final library = LegacyLibraryAdapter(backend: state);
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('${root.path}/book.txt');
      await file.writeAsString('第一章 测试\n正文\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final requests = <Map<String, dynamic>>[];
      Completer<String>? delay;
      final session = LegacyCatalogSession(
        state,
        library.books.value.single.id,
        request: ({required request, required cookie}) async {
          final value = jsonDecode(request) as Map<String, dynamic>;
          requests.add(value);
          expect(request, isNot(contains('session=fixture')));
          if (delay != null) return delay.future;
          if (value['source'] == 'search') {
            return jsonEncode({
              'stage': 'search_results',
              'books': [
                {
                  'book_id': '123',
                  'title': '测试小说',
                  'url': 'https://www.qidian.com/book/123/',
                },
              ],
            });
          }
          return jsonEncode({
            'stage': 'candidate',
            'from_cache': false,
            'catalog': {
              'title': '测试小说',
              'author': '',
              'origin': 'https://www.qidian.com/book/123/',
              'completeness': 'complete',
              'entries': [
                {'title': '第一章 测试', 'volume': '', 'volume_kind': 'unknown'},
              ],
            },
          });
        },
      );
      final results = await session.search(
        '  测试小说  ',
        cookie: 'session=fixture',
      );
      expect(results.single.id, '123');
      expect(requests.last['source'], 'search');
      expect(requests.last['input'], '测试小说');
      await session.acquire('qidian', results.single.url, useCache: false);
      expect(requests.last['use_cache'], false);
      delay = Completer<String>();
      final pending = session.search('另一书');
      final rejected = expectLater(pending, throwsA(isA<Exception>()));
      session.cancel();
      delay.complete(jsonEncode({'stage': 'search_results', 'books': []}));
      await rejected;
    },
  );
}
