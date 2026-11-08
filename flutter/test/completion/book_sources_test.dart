import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/infrastructure/legacy_catalog_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

void main() {
  test('book source service reaches native catalog, project restore and cancellation', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = await Directory.systemTemp.createTemp('v44-book-sources-');
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    final requests = <String>[];
    final waiting = Completer<void>();
    final release = Completer<void>();
    final serverErrors = <Object>[];
    server.listen((request) async {
      try {
        requests.add(request.uri.path);
        expect(request.headers.value('cookie'), isNull);
        expect(request.headers.value('authorization'), isNull);
        request.response.headers.contentType = ContentType.html;
        switch (request.uri.path) {
          case '/search':
            expect(request.uri.queryParameters['q'], '测试');
            request.response.write(
              '<ul><li><a href="/book">测试书</a><span>作者</span><b>第二章 乙</b></li></ul>',
            );
          case '/book':
            request.response.write(
              '<h1>测试书</h1><span>作者</span><a id="toc" href="/toc">目录</a>',
            );
          case '/toc':
            request.response.write(
              '<div class="list"><a href="/c1">第一章 甲</a></div><a id="next" href="/toc2">下一页</a>',
            );
          case '/toc2':
            request.response.write(
              '<div class="list"><a href="/c2">第二章 乙</a></div>',
            );
          case '/wait':
            waiting.complete();
            await release.future;
            request.response.write('<ul></ul>');
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      } catch (e) {
        // 主动取消的响应连接可能已经断开；断言失败仍必须上报。
        if (e is! SocketException && e is! HttpException) serverErrors.add(e);
      }
    });
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await server.close(force: true);
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    final original = File('${root.path}/book.txt');
    const text = '第一章 甲\n甲的正文\n第二章 乙\n乙的正文\n';
    await original.writeAsString(text);
    expect((await library.importFiles([original.path])).single.succeeded, true);
    final session = LegacyCatalogSession(state, library.books.value.single.id);
    final source = <String, dynamic>{
      'bookSourceName': '本机服务夹具',
      'bookSourceUrl': base,
      'bookSourceType': 0,
      'header': jsonEncode({
        'Cookie': 'FAKE_IMPORT_SECRET',
        'Authorization': 'FAKE_IMPORT_SECRET',
      }),
      'searchUrl': '/search?q={{key}}&page={{page}}',
      'ruleSearch': {
        'bookList': 'tag.li',
        'name': 'tag.a@text',
        'bookUrl': 'tag.a@href',
        'author': 'tag.span@text',
        'lastChapter': 'tag.b@text',
      },
      'ruleBookInfo': {
        'name': 'tag.h1@text',
        'author': 'tag.span@text',
        'tocUrl': 'id.toc@href',
      },
      'ruleToc': {
        'chapterList': 'class.list@tag.a',
        'chapterName': 'text',
        'chapterUrl': 'href',
        'nextTocUrl': 'id.next@href',
      },
    };
    final input = File('${root.path}/sources.json');
    await input.writeAsString(
      jsonEncode([
        source,
        {
          ...source,
          'bookSourceUrl': '$base/js',
          'ruleToc': {'chapterList': '@js:FAKE_SCRIPT_SECRET'},
        },
      ]),
    );
    final imported = await session.importBookSources(input.path);
    final supported = imported.singleWhere((s) => s.supported);
    final unsupported = imported.singleWhere((s) => !s.supported);
    expect(unsupported.reason, isNotEmpty);
    expect((await session.listBookSources()).length, 2);
    final found = await session.searchBookSource(supported.id, '测试');
    expect(found.single.title, '测试书');
    expect(found.single.author, '作者');
    expect(found.single.lastChapter, '第二章 乙');
    final snapshot = await session.acquireBookSource(found.single);
    expect(snapshot.origin, startsWith('source:'));
    expect(snapshot.entries.map((e) => e.title), ['第一章 甲', '第二章 乙']);
    expect(snapshot.completeness, 'unknown');
    expect(
      (await session.preview(snapshot, identityConfirmed: true)).matched,
      2,
    );
    session.accept(snapshot);
    final project = '${root.path}/saved.easypub.json';
    expect((await library.saveProject(project)).succeeded, true);
    expect((await library.openProject(project)).succeeded, true);
    final restored = LegacyCatalogSession(state, library.books.value.single.id);
    expect(restored.saved!.entries, hasLength(2));
    expect(
      (await restored.preview(
        restored.saved!,
        identityConfirmed: true,
      )).matched,
      2,
    );
    final count = requests.length;
    expect((await restored.acquireBookSource(found.single)).fromCache, true);
    expect(requests.length, count);
    // 即使直接调用者传入窗口 Cookie 和保存标志，书源分支也不能读取或发送它。
    final direct = jsonDecode(
      await api.catalogRequestText(
        request: jsonEncode({
          'op': 'acquire',
          'source': 'book_source_search',
          'book_source_id': supported.id,
          'input': '测试',
          'use_saved_cookie': true,
        }),
        cookie: 'sid=FAKE_WINDOW_SECRET',
      ),
    ) as Map;
    expect(direct['stage'], 'search_results');
    final local = Directory(
      '${Platform.environment['LOCALAPPDATA']}/EasyPubRustFlutter/book-sources-v1',
    );
    final stored = await File('${local.path}/sources.json').readAsString();
    expect(stored, isNot(contains('FAKE_IMPORT_SECRET')));
    expect(stored, isNot(contains('FAKE_SCRIPT_SECRET')));
    expect(await File(project).readAsString(), isNot(contains('FAKE_')));
    await input.writeAsString(
      jsonEncode({...source, 'searchUrl': '/wait?q={{key}}'}),
    );
    await restored.importBookSources(input.path);
    final pending = restored.searchBookSource(supported.id, '测试');
    final cancelled = expectLater(pending, throwsA(isA<Exception>()));
    await waiting.future.timeout(const Duration(seconds: 5));
    final competing = LegacyCatalogSession(
      state,
      library.books.value.single.id,
    );
    await expectLater(
      competing.searchBookSource(supported.id, '测试'),
      throwsA(isA<FormatException>()),
    );
    restored.cancel();
    await cancelled.timeout(const Duration(seconds: 5));
    release.complete();
    await restored.clearBookSources();
    expect(await restored.listBookSources(), isEmpty);
    expect(
      (await restored.preview(
        restored.saved!,
        identityConfirmed: true,
      )).matched,
      2,
    );
    expect(await original.readAsString(), text);
    expect(serverErrors, isEmpty);
  });
}
