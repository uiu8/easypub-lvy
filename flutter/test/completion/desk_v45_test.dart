import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/catalog_service.dart';
import 'package:easypub_desktop/desk/catalog/source_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

/// 假会话：同时实现目录会话与书源会话；可让抓取挂起，检验迟到结果被丢弃。
class FakeSources implements CatalogSession, BookSourceSession {
  List<BookSourceInfo> stored = const [];
  final imported = <String>[];
  final searches = <(String, String)>[];
  final acquired = <(String, bool)>[];
  int cancels = 0, clears = 0;
  Completer<CatalogSnapshot>? hold;

  static const usable = BookSourceInfo(
    id: 'a',
    name: '笔趣阁',
    url: 'https://www.example.com',
    group: '常用',
    supported: true,
    reasonCode: '',
    reason: '',
  );
  static const scripted = BookSourceInfo(
    id: 'b',
    name: '起点男频',
    url: 'https://m.qidian.com',
    group: '',
    supported: false,
    reasonCode: 'book_source_javascript_required',
    reason: '需要 JavaScript',
  );

  @override
  Future<List<BookSourceInfo>> listBookSources() async => stored;
  @override
  Future<List<BookSourceInfo>> importBookSources(String path) async {
    imported.add(path);
    return stored = const [usable, scripted];
  }

  @override
  Future<void> clearBookSources() async {
    clears++;
    stored = const [];
  }

  @override
  Future<List<BookSourceSearchResult>> searchBookSource(
    String sourceId,
    String query,
  ) async {
    searches.add((sourceId, query));
    return const [
      BookSourceSearchResult(
        'u1',
        '雾港来信',
        'https://www.example.com/book/1',
        sourceId: 'a',
        author: '林沉舟',
        lastChapter: '第二十六章 归帆',
      ),
      BookSourceSearchResult(
        'u2',
        '雾港',
        'https://www.example.com/book/2',
        sourceId: 'a',
        author: '',
        lastChapter: '',
      ),
    ];
  }

  @override
  Future<CatalogSnapshot> acquireBookSource(
    BookSourceSearchResult book, {
    bool useCache = true,
  }) {
    acquired.add((book.url, useCache));
    if (hold != null) return hold!.future;
    return Future.value(
      CatalogSnapshot(book.title, book.author, 'source:x', 'unknown', const [
        CatalogEntry('第一章 雾起', '第一卷 潮声', true),
        CatalogEntry('第二章 旧码头', '第一卷 潮声', true),
      ]),
    );
  }

  @override
  CatalogSnapshot? get saved => null;
  @override
  void cancel() => cancels++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 只有目录会话、没有书源能力的旧会话。
class PlainSession implements CatalogSession {
  @override
  CatalogSnapshot? get saved => null;
  @override
  void cancel() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// V45：获取参考目录的“书源目录”页签（CH-270–276）。
void main() {
  CatalogSnapshot? returned;
  Future<void> open(
    WidgetTester t,
    CatalogSession session, {
    Future<String?> Function()? pick,
  }) async {
    returned = null;
    t.view.physicalSize = const Size(1200, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  returned = await showDialog<CatalogSnapshot>(
                    context: context,
                    builder: (_) => CatalogSourceDialog(
                      session: session,
                      pickFile: () async => null,
                      pickBookSourceFile: pick,
                    ),
                  ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> toBookSourceTab(WidgetTester t) async {
    await t.tap(find.text('打开'));
    await t.pumpAndSettle();
    await t.tap(find.text('书源目录'));
    await t.pumpAndSettle();
  }

  testWidgets('空状态导入书源；下拉标出不可用原因；只显示可用；访问设置只在在线目录', (t) async {
    final session = FakeSources();
    await open(t, session, pick: () async => r'D:\书源\share.json');
    await t.pumpAndSettle();
    await toBookSourceTab(t);
    expect(find.byKey(const ValueKey('book-source-empty')), findsOneWidget);
    expect(find.text('访问设置'), findsNothing);
    expect(find.text('声明的章节总数（可选）'), findsNothing);
    await t.tap(find.byKey(const ValueKey('book-source-import')));
    await t.pumpAndSettle();
    expect(session.imported, [r'D:\书源\share.json']);
    expect(
      t.widget<Text>(find.byKey(const ValueKey('book-source-count'))).data,
      startsWith('可用 1 / 共 2 个书源'),
    );
    // 自动选中第一个可用书源。
    expect(find.text('笔趣阁'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('book-source-choice')));
    await t.pumpAndSettle();
    expect(find.text('需要 JavaScript'), findsOneWidget);
    final disabled = t.widget<MenuItemButton>(
      find.ancestor(
        of: find.text('起点男频'),
        matching: find.byType(MenuItemButton),
      ),
    );
    expect(disabled.onPressed, isNull);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('book-source-more')));
    await t.pumpAndSettle();
    await t.tap(find.text('只显示可用书源'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('book-source-choice')));
    await t.pumpAndSettle();
    expect(find.text('起点男频'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await t.tap(find.text('在线目录'));
    await t.pumpAndSettle();
    expect(find.text('访问设置'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('搜索书名 → 选结果抓目录 → 预览目录返回候选', (t) async {
    final session = FakeSources()..stored = const [FakeSources.usable];
    await open(t, session);
    await t.pumpAndSettle();
    await toBookSourceTab(t);
    final search = find.byKey(const ValueKey('book-source-search'));
    expect(
      t
          .widget<TextButton>(
            find.descendant(of: search, matching: find.byType(TextButton)),
          )
          .onPressed,
      isNull,
      reason: '没输入书名时不能搜索',
    );
    await t.enterText(find.widgetWithText(TextField, '书名'), '雾港来信');
    await t.pump();
    await t.tap(search);
    await t.pumpAndSettle();
    expect(session.searches, [('a', '雾港来信')]);
    expect(find.text('雾港来信 · 林沉舟'), findsOneWidget);
    expect(find.text('最新：第二十六章 归帆'), findsOneWidget);
    await t.tap(find.text('雾港来信 · 林沉舟'));
    await t.pumpAndSettle();
    expect(session.acquired, [('https://www.example.com/book/1', true)]);
    expect(find.textContaining('雾港来信 · 林沉舟 · 2 条目录'), findsOneWidget);
    await t.tap(find.text('预览目录'));
    await t.pumpAndSettle();
    expect(returned?.entries.length, 2);
    expect(t.takeException(), isNull);
  });

  testWidgets('抓取中关闭弹窗：请求取消，迟到结果不返回；换页签清空候选', (t) async {
    final session = FakeSources()
      ..stored = const [FakeSources.usable]
      ..hold = Completer<CatalogSnapshot>();
    await open(t, session);
    await t.pumpAndSettle();
    await toBookSourceTab(t);
    await t.enterText(find.widgetWithText(TextField, '书名'), '港口');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('book-source-search')));
    await t.pumpAndSettle();
    await t.tap(find.text('雾港'));
    await t.pump();
    expect(session.acquired.length, 1);
    expect(
      find.byKey(const ValueKey('book-source-fetching')),
      findsOneWidget,
      reason: '抓取期间说明可能需要几十秒、可以取消',
    );
    final before = session.cancels;
    await t.tap(find.text('取消').last);
    await t.pumpAndSettle();
    expect(session.cancels, greaterThan(before), reason: '关闭时取消进行中的请求');
    session.hold!.complete(
      const CatalogSnapshot('雾港', '', 'source:x', 'unknown', [
        CatalogEntry('第一章', '', false),
      ]),
    );
    await t.pumpAndSettle();
    expect(returned, isNull, reason: '迟到结果不能当作已选目录返回');

    // 重新打开：抓到候选后换页签，候选清空且请求被取消。
    session.hold = null;
    await t.tap(find.text('打开'));
    await t.pumpAndSettle();
    await t.tap(find.text('书源目录'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, '书名'), '港口');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('book-source-search')));
    await t.pumpAndSettle();
    await t.tap(find.text('雾港'));
    await t.pumpAndSettle();
    expect(find.textContaining('1 条目录'), findsNothing);
    expect(find.textContaining('雾港 · 作者未提供 · 2 条目录'), findsOneWidget);
    final cancels = session.cancels;
    await t.tap(find.text('本地目录'));
    await t.pumpAndSettle();
    expect(session.cancels, greaterThan(cancels));
    await t.tap(find.text('书源目录'));
    await t.pumpAndSettle();
    expect(find.textContaining('条目录'), findsNothing, reason: '切换后候选清空');
    expect(t.takeException(), isNull);
  });

  testWidgets('清空本机书源先确认，确认后回到空状态', (t) async {
    final session = FakeSources()..stored = const [FakeSources.usable];
    await open(t, session);
    await t.pumpAndSettle();
    await toBookSourceTab(t);
    await t.tap(find.byKey(const ValueKey('book-source-more')));
    await t.pumpAndSettle();
    await t.tap(find.text('清空本机书源…'));
    await t.pumpAndSettle();
    await t.tap(find.text('取消').last);
    await t.pumpAndSettle();
    expect(session.clears, 0);
    await t.tap(find.byKey(const ValueKey('book-source-more')));
    await t.pumpAndSettle();
    await t.tap(find.text('清空本机书源…'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('book-source-clear-confirm')));
    await t.pumpAndSettle();
    expect(session.clears, 1);
    expect(find.byKey(const ValueKey('book-source-empty')), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('没有书源能力的会话不显示书源页签', (t) async {
    await open(t, PlainSession());
    await t.pumpAndSettle();
    await t.tap(find.text('打开'));
    await t.pumpAndSettle();
    expect(find.text('书源目录'), findsNothing);
    expect(find.text('在线目录'), findsOneWidget);
  });
}
