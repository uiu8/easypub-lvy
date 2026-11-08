import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/inline_style_service.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/chapters/inline_style_marks.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _page1 =
    '<html xmlns="http://www.w3.org/1999/xhtml" '
    'xmlns:epub="http://www.idpf.org/2007/ops"><head><link rel="stylesheet" href="s.css"/></head><body>'
    '<h1>第一章 开始</h1>'
    '<p>开头第一行。</p><p>开头第二行。</p>'
    '<p>这里有<b>粗体</b>和<i>斜体</i>，<span class="zhong">类粗体</span>。</p>'
    '<p>水是H<sub>2</sub>O，看<a href="https://example.com/a">这个网站</a>。</p>'
    '<p>说明<a epub:type="noteref" href="#n1">[1]</a>，还有<a href="p2.xhtml#x">跳到别处</a>。</p>'
    '<table><tr><th>名</th><th>值</th></tr><tr><td>甲表格字</td><td>一</td></tr></table>'
    '<p id="n1">[1] 这是脚注正文。</p>'
    '</body></html>';
const _page2 =
    '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1 id="x">第二章 继续</h1>'
    '<p>这里也有<b>粗体二</b>。</p></body></html>';

/// 不压缩的 ZIP，够读取端用。
List<int> _zipOf(Map<String, String> files) {
  int crc(List<int> bytes) {
    var c = 0xffffffff;
    for (final b in bytes) {
      c ^= b;
      for (var i = 0; i < 8; i++) {
        c = c & 1 == 1 ? (c >>> 1) ^ 0xedb88320 : c >>> 1;
      }
    }
    return c ^ 0xffffffff;
  }

  final body = BytesBuilder();
  final central = BytesBuilder();
  ByteData block(int size) => ByteData(size);
  files.forEach((name, text) {
    final data = utf8.encode(text), path = utf8.encode(name);
    final sum = crc(data), at = body.length;
    final local = block(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x800, Endian.little)
      ..setUint32(14, sum, Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, data.length, Endian.little)
      ..setUint16(26, path.length, Endian.little);
    body
      ..add(local.buffer.asUint8List())
      ..add(path)
      ..add(data);
    final row = block(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0x800, Endian.little)
      ..setUint32(16, sum, Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, data.length, Endian.little)
      ..setUint16(28, path.length, Endian.little)
      ..setUint32(42, at, Endian.little);
    central
      ..add(row.buffer.asUint8List())
      ..add(path);
  });
  final end = block(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, files.length, Endian.little)
    ..setUint16(10, files.length, Endian.little)
    ..setUint32(12, central.length, Endian.little)
    ..setUint32(16, body.length, Endian.little);
  return [...body.toBytes(), ...central.toBytes(), ...end.buffer.asUint8List()];
}

File _epub(String path) => File(path)
  ..writeAsBytesSync(
    _zipOf({
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OEBPS/c.opf"/></rootfiles></container>',
      'OEBPS/c.opf':
          '<package xmlns="http://www.idpf.org/2007/opf"><metadata/><manifest>'
          '<item id="a" href="p1.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="b" href="p2.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="c" href="s.css" media-type="text/css"/></manifest>'
          '<spine><itemref idref="a"/><itemref idref="b"/></spine></package>',
      'OEBPS/s.css': '.zhong { font-weight: bold }',
      'OEBPS/p1.xhtml': _page1,
      'OEBPS/p2.xhtml': _page2,
    }),
  );

Future<String> _convert(
  PrototypeState state,
  String id,
  String directory,
  String format,
) async {
  Directory(directory).createSync(recursive: true);
  final session = LegacyConversionSession(state);
  try {
    final plan = await session.preview(
      ConversionRequest(
        books: [id],
        directory: directory,
        format: format,
        engine: switch (format) {
          'KFX' => Platform.environment['EASYPUB_TEST_BOKAI']!,
          'AZW3' || 'MOBI' => Platform.environment['EASYPUB_TEST_KINDLING']!,
          _ => '',
        },
        generateCover: true,
        runChecks: false,
      ),
    );
    expect(
      plan.previewed,
      true,
      reason: plan.findings.map((e) => e.detail).join('\n'),
    );
    final result = (await session.commit(
      plan,
      acknowledgeWarnings: true,
    )).single;
    expect(result.complete, true, reason: result.detail);
    return result.path;
  } finally {
    session.dispose();
  }
}

/// 中央目录比本地文件头可靠：我们写的 ZIP 大小可能写在数据描述符里。
Map<String, String> _unzip(List<int> zip) {
  final data = ByteData.sublistView(Uint8List.fromList(zip));
  var end = zip.length - 22;
  while (data.getUint32(end, Endian.little) != 0x06054b50) {
    end--;
  }
  var at = data.getUint32(end + 16, Endian.little);
  final count = data.getUint16(end + 10, Endian.little);
  final files = <String, String>{};
  for (var i = 0; i < count; i++) {
    final method = data.getUint16(at + 10, Endian.little);
    final size = data.getUint32(at + 20, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extra = data.getUint16(at + 30, Endian.little);
    final comment = data.getUint16(at + 32, Endian.little);
    final offset = data.getUint32(at + 42, Endian.little);
    final name = utf8.decode(zip.sublist(at + 46, at + 46 + nameLength));
    final start =
        offset +
        30 +
        data.getUint16(offset + 26, Endian.little) +
        data.getUint16(offset + 28, Endian.little);
    final body = zip.sublist(start, start + size);
    if (name.endsWith('html') || name.endsWith('.css')) {
      files[name] = utf8.decode(
        method == 0 ? body : ZLibDecoder(raw: true).convert(body),
        allowMalformed: true,
      );
    }
    at += 46 + nameLength + extra + comment;
  }
  return files;
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  late Directory root;
  late PrototypeState state;
  late LegacyLibraryAdapter library;

  setUp(() async {
    root = await Directory('../artifacts').createTemp('source-marks-');
    state = PrototypeState(settingsDirectory: '${root.absolute.path}/settings');
    library = LegacyLibraryAdapter(backend: state);
    await library.load();
    await library.savePatch({'check_after_import': false});
  });
  tearDown(() async {
    library.dispose();
    state.dispose();
    await root.delete(recursive: true);
  });

  Future<String> import(String name) async {
    final file = _epub('${root.absolute.path}/$name.epub');
    await library.importFiles([file.path]);
    return state.currentId;
  }

  Future<InlineStyleSnapshot> styles(String id) async {
    final session = library.openInlineStyles(id);
    try {
      return await session.list();
    } finally {
      session.dispose();
    }
  }

  test('导入后样式、脚注、表格都在，改前面的正文也不失效', () async {
    final id = await import('书');
    expect(state.importStatus, contains('1 张表格'));
    expect(state.importStatus, contains('1 个书内跳转链接未保留'));
    final draft = state.production.drafts[id]!;
    expect(draft.sourceMarks?['tables'], 1);

    var list = await styles(id);
    String shown(InlineStyleSnapshot s) =>
        (s.items.map((v) => '${v.style}:${v.text}').toList()..sort()).join('|');
    expect(list.invalidCount, 0);
    expect(list.items.every((v) => v.source), true);
    const all = 'bold:类粗体|bold:粗体|bold:粗体二|italic:斜体|link:这个网站|sub:2';
    expect(shown(list), all);
    expect(
      list.items.firstWhere((v) => v.style == 'link').href,
      'https://example.com/a',
    );
    expect(list.tables.single.rows[1][0].text, '甲表格字');
    expect(list.tables.single.location, isNotNull);

    final notes = library.openManualNotes(id);
    final snapshot = await notes.list();
    notes.dispose();
    expect(
      snapshot.notes.where((n) => n.marker == '[1]').length,
      1,
      reason: '脚注链接要变成注释',
    );

    // 删掉本章前面两行，后面所有行的字节位置都变了。手工样式这时会失效，原书的不会。
    final chapters = library.openChapters(id);
    final page = await chapters.read(0, includeBody: true);
    final chapter = page.nodes.first;
    final body = await chapters.body(page, chapter.id, 0);
    final first = body.rows
        .firstWhere((r) => r.text.contains('开头第一行'))
        .lineOffset;
    await chapters.confirm(
      await chapters.preview(
        page,
        ExcludeChapterBodyLines(chapter.id, first, first + 1),
      ),
    );
    list = await styles(id);
    expect(shown(list), all);
    expect(list.tables, hasLength(1));

    // 一条条删：列表里少一条，能退回。
    final session = library.openInlineStyles(id);
    final bold = list.items.firstWhere((v) => v.text == '粗体');
    await session.confirm(await session.previewDelete(bold.id));
    session.dispose();
    expect(shown(await styles(id)), isNot(contains('bold:粗体|')));
    expect(state.production.settings(id)['source_marks']['removed'], [bold.id]);

    // 改网址：换成一条手工链接。
    final edit = library.openInlineStyles(id);
    final current = await edit.list();
    final link = current.items.firstWhere((v) => v.style == 'link');
    await edit.confirm(
      await edit.previewUpdate(
        current,
        link.id,
        InlineStyleDraft(link.anchor, 'link', href: 'https://example.com/b'),
      ),
    );
    edit.dispose();
    final changed = (await styles(id)).items
        .firstWhere((v) => v.style == 'link');
    expect(changed.href, 'https://example.com/b');
    expect(changed.source, false);

    // 一键全部移除，表格还在；恢复后回来。
    final layout = library.openLayout(id);
    final marks = Map<String, Object?>.from(
      state.production.settings(id)['source_marks'] as Map,
    );
    await layout.apply(
      await layout.preview({
        'source_marks': {...marks, 'styles_off': true},
      }),
    );
    final off = await styles(id);
    expect(off.items.where((v) => v.source), isEmpty);
    expect(off.tables, hasLength(1));
    layout.dispose();

    // 整张删表：成品里没有。
    final table = library.openInlineStyles(id);
    await table.confirm(await table.previewDelete(off.tables.single.id));
    table.dispose();
    expect((await styles(id)).tables.single.removed, true);
    final path = await _convert(
      state,
      id,
      '${root.absolute.path}/removed',
      'EPUB',
    );
    final html = _unzip(File(path).readAsBytesSync()).values.join();
    expect(html, isNot(contains('甲表格字')));
    expect(html, isNot(contains('>〔表格')));
  });

  test('五种格式都走得通，EPUB 和 TXT 里内容都在', () async {
    final id = await import('书');
    final epub = await _convert(
      state,
      id,
      '${root.absolute.path}/epub',
      'EPUB',
    );
    final files = _unzip(File(epub).readAsBytesSync());
    final html = files.values.join();
    for (final piece in [
      '<span class="inline-bold">粗体</span>',
      'H<span class="inline-sub">2</span>O',
      '<a class="inline-link" href="https://example.com/a">这个网站</a>',
      '<th>名</th>',
      '<td>甲表格字</td>',
      'epub:type="noteref"',
    ]) {
      expect(html, contains(piece));
    }
    expect(html, contains('.book-table'));
    expect(html, contains('.inline-bold'));
    final txt = await _convert(state, id, '${root.absolute.path}/txt', 'TXT');
    final text = File(txt).readAsStringSync();
    expect(text, contains('甲表格字 一'));
    expect(text, isNot(contains('〔表格')));
    for (final format in ['AZW3', 'MOBI', 'KFX']) {
      final path = await _convert(
        state,
        id,
        '${root.absolute.path}/$format',
        format,
      );
      expect(File(path).lengthSync(), greaterThan(0));
    }
  });

  test('AZW3、MOBI、KFX 成品读回来，表格和样式都在', () async {
    final calibre = Platform.environment['EASYPUB_TEST_CALIBRE'];
    if (calibre == null) return;
    final id = await import('书');
    // 开注释的 KFX Calibre 读不了（已知问题），这里去掉脚注看表格和样式。
    final notes = library.openManualNotes(id);
    final snapshot = await notes.list();
    await notes.confirm(
      await notes.previewDelete(
        snapshot.notes.firstWhere((n) => n.marker == '[1]').id,
      ),
    );
    notes.dispose();
    for (final format in ['AZW3', 'MOBI', 'KFX']) {
      final path = await _convert(
        state,
        id,
        '${root.absolute.path}/back-$format',
        format,
      );
      final back = '${root.absolute.path}/back-$format.epub';
      final run = await Process.run(calibre, [path, back]);
      expect(run.exitCode, 0, reason: '$format：${run.stdout}');
      final html = _unzip(File(back).readAsBytesSync()).values.join();
      expect(html, contains('甲表格字'), reason: format);
      expect(html, contains('<table'), reason: format);
      expect(html, contains('这个网站'), reason: format);
      expect(html, contains('https://example.com/a'), reason: format);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('AZW3 导回来走同一条路，粗体和表格还在', () async {
    final id = await import('书');
    final azw3 = await _convert(
      state,
      id,
      '${root.absolute.path}/azw3',
      'AZW3',
    );
    await library.importFiles([azw3]);
    final again = state.currentId;
    expect(again, isNot(id));
    final list = await styles(again);
    expect(list.items.map((v) => v.text), contains('粗体'));
    expect(list.tables, hasLength(1));
  });

  test('设置里关掉就和以前一样；旧书能补读', () async {
    await library.savePatch({'keep_source_marks': false});
    final id = await import('旧书');
    expect(state.production.settings(id)['source_marks'], isNull);
    expect((await styles(id)).items, isEmpty);
    final source = state.shelf.books.firstWhere((b) => b.id == id).source!;
    expect(File(source.path).readAsStringSync(), contains('名值\n甲表格字一\n'));

    final report = await library.rereadSourceMarks(id);
    expect(report['styles'], greaterThan(0));
    expect(report['tables'], 0);
    final selection = sourceMarkSelection({'source_marks': report})!;
    final layout = library.openLayout(id);
    await layout.apply(await layout.preview({'source_marks': selection}));
    layout.dispose();
    final list = await styles(id);
    expect(list.items.map((v) => v.text), contains('粗体'));
    expect(list.tables, isEmpty);

    // 工作稿和原书对不上时不能补读。
    final other = File('${root.absolute.path}/别的.txt')
      ..writeAsStringSync('不一样\n');
    await expectLater(
      api.rereadEpubMarks(
        sourcePath: source.originPath!,
        textPath: other.path,
        resourceDir: '${root.absolute.path}/m',
      ),
      throwsA(isA<api.ApiError>()),
    );
  });

  testWidgets('章节页只读显示表格，能整张删', (t) async {
    late String id;
    await t.runAsync(() async => id = await import('书'));
    late InlineStyleController controller;
    await t.runAsync(() async {
      controller = InlineStyleController(library.openInlineStyles(id));
      for (var i = 0; i < 200 && controller.snapshot == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    addTearDown(controller.dispose);
    final table = controller.snapshot!.tables.single;
    final entry = table.location!.entryId;
    expect(controller.tablesFor(entry)[table.location!.line]?.id, table.id);
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => SourceTableCard(
              table: controller.snapshot!.tables.single,
              controller: controller,
            ),
          ),
        ),
      ),
    );
    expect(find.text('甲表格字'), findsOneWidget);
    expect(find.text('名'), findsOneWidget);
    await t.runAsync(() => controller.removeTable(table));
    await t.pump();
    expect(find.text('甲表格字'), findsNothing);
    expect(find.textContaining('这张表已删除'), findsOneWidget);
  });

  Future<void> settle(WidgetTester t, bool Function() ready) async {
    for (var i = 0; i < 400; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (ready()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    fail('界面未就绪');
  }

  testWidgets('章节页打开就能看到表格；更多菜单能补读旧书', (t) async {
    t.view.physicalSize = const Size(1400, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late String id, old;
    final capture = GlobalKey();
    final capturePath = Platform.environment['EASYPUB_MARKS_SCREENSHOT'];
    await t.runAsync(() async {
      if (capturePath != null) {
        await loadDeskFonts();
        await (FontLoader('MaterialIcons')..addFont(
              File(
                'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
        await (FontLoader('Microsoft YaHei')..addFont(
              File('C:/Windows/Fonts/msyh.ttc')
                  .readAsBytes()
                  .then((b) => b.buffer.asByteData()),
            ))
            .load();
      }
      id = await import('书');
      await library.savePatch({'keep_source_marks': false});
      old = await import('旧书');
    });
    Widget page(String book) => RepaintBoundary(
      key: capture,
      child: MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChapterWorkspace(
            key: ValueKey(book),
            library: library,
            bookId: book,
          ),
        ),
      ),
    );
    await t.pumpWidget(page(id));
    await settle(t, () => find.text('第一章 开始').evaluate().isNotEmpty);
    await t.tap(find.text('第一章 开始').first);
    await settle(t, () => find.byType(SourceTableCard).evaluate().isNotEmpty);
    expect(find.text('甲表格字'), findsOneWidget);

    if (capturePath != null) {
      await t.pump(const Duration(milliseconds: 300));
      final boundary =
          capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await t.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        await File(capturePath).writeAsBytes(bytes);
        image.dispose();
      });
    }

    await t.pumpWidget(page(old));
    await settle(t, () => find.text('第一章 开始').evaluate().isNotEmpty);
    await t.tap(find.text('第一章 开始').first);
    await settle(t, () => find.textContaining('开头第一行').evaluate().isNotEmpty);
    expect(state.production.settings(old)['source_marks'], isNull);
    final more = find.byTooltip('更多章节操作').first;
    await t.tap(more);
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('从原书补读行内样式'));
    await settle(
      t,
      () => state.production.settings(old)['source_marks'] != null,
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await settle(t, () => find.textContaining('已补读').evaluate().isNotEmpty);
    expect(find.textContaining('要保留表格请重新导入'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('排版页显示共几处，一键移除后还能恢复', (t) async {
    t.view.physicalSize = const Size(1300, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late String id;
    await t.runAsync(() async => id = await import('书'));
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: LayoutPage(
            library: library,
            bookId: id,
            navigation: LayoutNavigationGuard(),
            pickPresetFile: () async => null,
            pickPresetDestination: () async => null,
            importCss: () async => null,
            keepsOriginal: () => false,
            setKeepsOriginal: (_) {},
          ),
        ),
      ),
    );
    final row = find.byKey(const ValueKey('layout-source-marks'));
    await settle(t, () => row.evaluate().isNotEmpty);
    expect(find.text('原书行内样式：共 7 处'), findsOneWidget);
    final toggle = find.byKey(const ValueKey('layout-source-marks-toggle'));
    await t.ensureVisible(toggle);
    await t.pump();
    await t.tap(toggle);
    await settle(t, () => find.text('原书行内样式：已全部移除').evaluate().isNotEmpty);
    expect(state.production.settings(id)['source_marks']['styles_off'], true);
    expect((await t.runAsync(() => styles(id)))!.items, isEmpty);
    await t.tap(toggle);
    await settle(t, () => find.text('原书行内样式：共 7 处').evaluate().isNotEmpty);
    expect((await t.runAsync(() => styles(id)))!.items, isNotEmpty);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  test('出版物常见写法：DOCTYPE、命名字符、封面页，导入和保持原格式都走得通', () async {
    const head =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" '
        '"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">'
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>页</title></head><body>';
    final file = File('${root.absolute.path}/出版物.epub')
      ..writeAsBytesSync(
        _zipOf({
          'mimetype': 'application/epub+zip',
          'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OEBPS/c.opf"/></rootfiles></container>',
          'OEBPS/c.opf':
              '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
              '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">a</dc:identifier>'
              '<dc:title>出版物</dc:title><dc:language>zh</dc:language></metadata><manifest>'
              '<item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>'
              '<item id="a" href="p1.xhtml" media-type="application/xhtml+xml"/>'
              '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
              '</manifest><spine><itemref idref="cover"/><itemref idref="a"/></spine></package>',
          'OEBPS/nav.xhtml':
              '$head<nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="toc"><ol><li><a href="p1.xhtml">第一章</a></li></ol></nav></body></html>',
          'OEBPS/cover.xhtml': '$head<p>封面页</p></body></html>',
          'OEBPS/p1.xhtml':
              '$head<h1>第一章 开始</h1><p>甲&nbsp;乙&mdash;丙，<b>粗体</b>。</p></body></html>',
        }),
      );
    await library.importFiles([file.path]);
    final id = state.currentId;
    expect(state.importStatus, contains('已提取'));
    expect(
      File(state.shelf.books.firstWhere((b) => b.id == id).source!.path)
          .readAsStringSync(),
      contains('甲 乙—丙，粗体。'),
    );
    expect((await styles(id)).items.map((v) => v.text), contains('粗体'));
    for (final format in ['EPUB', 'AZW3', 'MOBI', 'KFX']) {
      final session = LegacyConversionSession(state);
      final dir = '${root.absolute.path}/keep-$format';
      Directory(dir).createSync();
      final plan = await session.preview(
        ConversionRequest(
          books: [id],
          directory: dir,
          format: format,
          engine: switch (format) {
            'KFX' => Platform.environment['EASYPUB_TEST_BOKAI']!,
            'EPUB' => '',
            _ => Platform.environment['EASYPUB_TEST_KINDLING']!,
          },
          generateCover: true,
          runChecks: false,
          keepOriginalEpub: {id},
        ),
      );
      final result = (await session.commit(
        plan,
        acknowledgeWarnings: true,
      )).single;
      session.dispose();
      expect(result.complete, true, reason: '$format ${result.detail}');
    }
  });

  test('读不出来的书说真实原因，不说路径和权限', () async {
    final file = File('${root.absolute.path}/坏.epub')
      ..writeAsBytesSync(
        _zipOf({
          'mimetype': 'application/epub+zip',
          'META-INF/container.xml': '<container><rootfiles><rootfile full-path="c.opf"/></rootfiles></container>',
          'c.opf': '<package xmlns="http://www.idpf.org/2007/opf"><metadata/><manifest><item id="a" href="p.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/></spine></package>',
          'p.xhtml': '<html><body><p>没有闭合</body></html>',
        }),
      );
    await library.importFiles([file.path]);
    expect(state.importStatus, contains('格式错误'));
    expect(state.importStatus, isNot(contains('权限')));
  });

  test('标记文件丢了不挡转换，表格和样式不带', () async {
    final id = await import('书');
    final marks = Map<String, Object?>.from(
      state.production.settings(id)['source_marks'] as Map,
    );
    File(marks['path'] as String).deleteSync();
    final layout = library.openLayout(id);
    await layout.apply(
      await layout.preview({
        'source_marks': {...marks, 'sha256': '0' * 64},
      }),
    );
    layout.dispose();
    final path = await _convert(
      state,
      id,
      '${root.absolute.path}/lost',
      'EPUB',
    );
    expect(File(path).existsSync(), true);
  });

  test('一列的表格按普通文字读', () async {
    final file = File('${root.absolute.path}/一列.epub')
      ..writeAsBytesSync(
        _zipOf({
          'mimetype': 'application/epub+zip',
          'META-INF/container.xml': '<container><rootfiles><rootfile full-path="c.opf"/></rootfiles></container>',
          'c.opf': '<package xmlns="http://www.idpf.org/2007/opf"><metadata/><manifest><item id="a" href="p.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/></spine></package>',
          'p.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml"><body><table><tr><td>正文甲</td></tr><tr><td>正文乙</td></tr></table></body></html>',
        }),
      );
    await library.importFiles([file.path]);
    final text = File(
      state.shelf.books.firstWhere((b) => b.id == state.currentId).source!.path,
    ).readAsStringSync();
    expect(text, contains('正文甲\n正文乙'));
    expect(text, isNot(contains('〔表格')));
  });
}
