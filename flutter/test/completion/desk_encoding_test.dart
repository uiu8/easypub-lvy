import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/source_refresh_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/library/encoding_dialog.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/library/library_view_state.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

class _Picker extends Fake implements BookFilePicker {
  @override
  Future<List<String>> chooseBooks() async => [];
}

/// 用 Big5 存的三行繁体：第一章 回家、門口……
const _big5Hex =
    'b2c4a440b3b920a65eae610aa54ca8aba8ecaaf9a466a141acdda8a3b07ca46cb8ccaabaa8bab4caa6d1bef0c1d9a662a143b36fac4fa54ca470aec9add4b160b160aaa6a457a568aab1aabaa661a4e8a141b27ba662a477b867aaf8b16fabdcb0aaa446a1430aa175a741a65ea8d3a446a143a176a5c0bfcbb171abceb8cca558a8d3a141a4e2b8ccc1d9aeb3b5dba853a6b3ac7ea7b9aabab5e6a143a54ca853a6b3bba1b8dca141a575ac4fc249a446c249c059a1430a';

Uint8List _hex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

/// 反复几十行，够判断。
Uint8List _big5Book() {
  final bytes = BytesBuilder();
  for (var i = 0; i < 40; i++) {
    bytes.add(_hex(_big5Hex));
  }
  return bytes.toBytes();
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
    root = await Directory('../artifacts').createTemp('encoding-');
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

  File write(String name, List<int> bytes) =>
      File('${root.absolute.path}/$name')..writeAsBytesSync(bytes);

  BookSummary summary(String id) =>
      library.books.value.firstWhere((b) => b.id == id);

  Future<String> text(String id) =>
      File(state.shelf.books.firstWhere((b) => b.id == id).source!.path)
          .readAsString();

  test('像乱码的书标出来，换成对的编码后文字对了、提示没了', () async {
    final file = write('繁体.txt', _big5Book());
    await library.importFiles([file.path]);
    final id = state.currentId;
    expect(summary(id).encodingSuspect, true);
    expect(state.importStatus, contains('编码可能不对'));

    final probe = await library.probeEncoding(file.path);
    expect(probe.auto, 'cp936');
    expect(probe.suspect, true);
    expect(probe.suggested, 'big5');
    final big5 = probe.candidates.firstWhere((c) => c.label == 'big5');
    expect(big5.ok, true);
    expect(big5.lines.first, startsWith('第一章'));

    // 这本书还没改过：直接换。
    expect(library.hasEdits(id), false);
    final preview = await library.previewEncodingChange(id, 'big5');
    expect(preview!.bodyChanged, true);
    final result = await (library as SourceRefreshService).applySourceRefresh(
      preview,
      fields: const {},
      replaceBody: true,
    );
    expect(result.recoveryPath, isNotNull);
    expect(await text(id), contains('第一章 回家'));
    expect(await text(id), contains('門口'));
    expect(summary(id).encodingSuspect, false);
    expect(summary(id).path, file.path, reason: '书库里还是原文件');
    expect(file.readAsBytesSync(), _big5Book(), reason: '原文件不动');

    // 项目保存再打开，编码记得；刷新来源按选的编码读，不退回 GBK。
    final row = (state.projectDocument()['books'] as List).single as Map;
    expect(row['source_encoding'], 'big5');
    expect(row.containsKey('encoding_suspect'), false);
    final again = await library.previewSourceRefresh(id);
    expect(again.bodyChanged, false);

    // 有修改时能判断出来。
    final chapters = library.openChapters(id);
    final page = await chapters.read(0, includeBody: true);
    final body = await chapters.body(page, page.nodes.first.id, 0);
    final row2 = body.rows[1].lineOffset;
    await chapters.confirm(
      await chapters.preview(
        page,
        ExcludeChapterBodyLines(page.nodes.first.id, row2, row2),
      ),
    );
    expect(library.hasEdits(id), true);

    // 真的存成项目再打开：新字段要过严格校验，编码还在。
    final project = '${root.absolute.path}/书.easypub.json';
    expect((await library.saveProject(project)).succeeded, true);
    expect((await library.openProject(project)).succeeded, true);
    final reopened = state.shelf.books.firstWhere((b) => b.id == id).source!;
    expect(reopened.sourceEncoding, 'big5');
    expect(reopened.encodingSuspect, false);
  });

  test('标记存进项目，再打开还在', () async {
    final file = write('繁体.txt', _big5Book());
    await library.importFiles([file.path]);
    final id = state.currentId;
    final project = '${root.absolute.path}/标记.easypub.json';
    expect((await library.saveProject(project)).succeeded, true);
    expect((await library.openProject(project)).succeeded, true);
    expect(summary(id).encodingSuspect, true);
  });

  test('现在的编码就是对的：只去掉提示，书稿不动', () async {
    final file = write('繁体.txt', _big5Book());
    await library.importFiles([file.path]);
    final id = state.currentId;
    final path = state.shelf.books.firstWhere((b) => b.id == id).source!.path;
    expect(await library.previewEncodingChange(id, 'cp936'), isNull);
    expect(summary(id).encodingSuspect, false);
    expect(state.shelf.books.firstWhere((b) => b.id == id).source!.path, path);
  });

  test('解不开的文件等用户选，选了就能导入，已有修改时能判断', () async {
    // 半角片假名后面跟空格，GBK 解不开，Shift_JIS 解得开。
    final bad = write(
      '打不开.txt',
      _hex(
        '91e688ea8fcd208b418bbd0ab120b220b32094bc8a70834a835e834a836982cc8d730a94de82cd96e582cc914f82c997a782c182c4814192eb82cc8cc382a296d882f08ca982bd81420a',
      ),
    );
    final outcome = (await library.importFiles([bad.path])).single;
    expect(outcome.succeeded, false);
    expect(library.undecodedFiles.value, [bad.path]);
    expect(state.importStatus, contains('请选择编码'));

    final probe = await library.probeEncoding(bad.path);
    expect(probe.auto, isNull);
    expect(probe.suggested, 'shift_jis');
    library.dropUndecoded(bad.path);
    expect(library.undecodedFiles.value, isEmpty);
    expect(await library.importWithEncoding(bad.path, 'shift_jis'), true);
    expect(await text(state.currentId), contains('彼は門の前'));

    // 选了编码能进书库，普通 TXT 的章节规则照用。
    final encoded = write('繁体二.txt', _big5Book());
    expect(await library.importWithEncoding(encoded.path, 'big5'), true);
    final id = state.currentId;
    expect(await text(id), contains('門口'));
    expect(summary(id).encodingSuspect, false);
    expect(state.importStatus, contains('big5'));
    expect(summary(id).format, 'TXT');
    // 选错编码不留半成品。
    expect(
      await library.importWithEncoding(write('错.txt', [0x81]).path, 'utf-8'),
      false,
    );
  });

  test('UTF-8 和正常 GBK 不打扰', () async {
    final utf = write('好.txt', _utf8());
    await library.importFiles([utf.path]);
    expect(summary(state.currentId).encodingSuspect, false);
    expect(library.undecodedFiles.value, isEmpty);
  });

  test('后台解码失败只进入待处理队列，手工导入仍请求选择编码', () async {
    final file = write('后台.txt', [0x81]);
    expect(
      (await library.importFiles([
        file.path,
      ], interactive: false)).single.succeeded,
      false,
    );
    expect(library.undecodedFiles.value, isEmpty);
    expect(library.pendingEncodingFiles.value, [file.path]);
    await library.importFiles([file.path]);
    expect(library.undecodedFiles.value, [file.path]);
    library.dropUndecoded(file.path);
    expect(library.pendingEncodingFiles.value, isEmpty);
  });

  test('撤销回起点不算修改，结构、清理、样式和注释均提示', () async {
    await library.importFiles([write('修改.txt', _utf8()).path]);
    final id = state.currentId;
    for (final histories in [
      state.manuscript.effectiveHistories,
      state.manuscript.manualEditDrafts,
      state.manuscript.structureHistories,
      state.cleanup.histories,
    ]) {
      histories[id] = {
        'history': [null, null],
        'cursor': 1,
      };
      expect(library.hasEdits(id), true);
      histories[id]!['cursor'] = 0;
      expect(library.hasEdits(id), false);
      histories.remove(id);
    }
    final draft = state.production.drafts[id]!;
    for (final marks in [
      draft.inlineStyles,
      draft.manualNotes,
      draft.blockAnnotations,
    ]) {
      marks.add({'test': true});
      expect(library.hasEdits(id), true);
      marks.clear();
      expect(library.hasEdits(id), false);
    }
  });

  test('刷新后的 TXT 仍按原始扩展名识别，EPUB 的 TXT 工作稿不算 TXT', () {
    ImportedTxt source(String? origin) => ImportedTxt(
      path: 'work.txt',
      originPath: origin,
      sourceId: 'test',
      revision: 1,
      encoding: 'utf-8',
      lines: 1,
      headings: 1,
    );
    expect(source(null).isPlainText, true);
    expect(source('原书.TXT').isPlainText, true);
    expect(source('原书.epub').isPlainText, false);
  });

  Future<void> waitFor(WidgetTester t, Finder finder) async {
    for (var i = 0; i < 300 && finder.evaluate().isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
  }

  for (final compact in [false, true]) {
    testWidgets('书库编码提示可点且修改确认可取消：列表=$compact', (t) async {
      t.view.physicalSize = const Size(1200, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.runAsync(
        () async => library.importFiles([write('繁体.txt', _big5Book()).path]),
      );
      final id = state.currentId;
      state.production.drafts[id]!.manualNotes.add({'test': true});
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: LibraryPage(
              library: library,
              picker: _Picker(),
              viewState: LibraryViewState()..compact = compact,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('书籍操作：${summary(id).title}'));
      await t.pumpAndSettle();
      expect(find.text('更换编码重新读取…'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey(('encoding-suspect', id))));
      await waitFor(t, find.byKey(const ValueKey(('encoding-lines', 'big5'))));
      await t.tap(find.byKey(const ValueKey('encoding-use')));
      await waitFor(t, find.byKey(const ValueKey('encoding-change-confirm')));
      expect(find.textContaining('打开刷新前的书稿'), findsWidgets);
      await t.tap(find.text('取消').last);
      await t.pumpAndSettle();
      expect(summary(id).encodingSuspect, true);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets('后台导入不弹窗，书库显示待处理；手动导入自动弹窗', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(RewriteApp(library: library, picker: _Picker()));
    await waitFor(t, find.byType(LibraryPage));
    late File file;
    late Future<List<ImportOutcome>> pending;
    await t.runAsync(() async {
      file = write('待处理.txt', [0x81]);
      pending = library.importFiles([file.path], interactive: false);
    });
    await waitFor(t, find.byKey(const ValueKey('pending-encoding-files')));
    await t.runAsync(() => pending);
    expect(find.byType(EncodingDialog), findsNothing);
    expect(
      find.byKey(const ValueKey('pending-encoding-files')),
      findsOneWidget,
    );
    await t.runAsync(() async {
      pending = library.importFiles([file.path]);
    });
    await waitFor(t, find.byType(EncodingDialog));
    await t.runAsync(() => pending);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('选编码窗口：切换编码看到不同的文字，选中后返回', (t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late File file;
    await t.runAsync(() async {
      file = write('繁体.txt', _big5Book());
      if (Platform.environment['EASYPUB_ENCODING_SCREENSHOT'] != null) {
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
    });
    String? picked = 'none';
    await t.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('encoding-capture'),
        child: MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => picked = await showEncodingDialog(
                  context,
                  library,
                  file.path,
                  note: '选一个',
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开'));
    await t.pump();
    final lines = find.byKey(const ValueKey(('encoding-lines', 'big5')));
    for (var i = 0; i < 300 && lines.evaluate().isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await t.pump(const Duration(milliseconds: 20));
    }
    // 建议的编码先选中，看得到正确的文字。
    expect(find.textContaining('第一章 回家'), findsWidgets);
    final capture = Platform.environment['EASYPUB_ENCODING_SCREENSHOT'];
    if (capture != null) {
      await t.pumpAndSettle();
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('encoding-capture')),
      );
      await t.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        await File(capture).writeAsBytes(bytes);
        image.dispose();
      });
    }
    await t.tap(find.byKey(const ValueKey(('encoding-choice', 'cp936'))));
    await t.pump();
    expect(find.textContaining('第一章 回家'), findsNothing);
    await t.tap(find.byKey(const ValueKey(('encoding-choice', 'big5'))));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('encoding-use')));
    await t.pump(const Duration(milliseconds: 300));
    expect(picked, 'big5');
  });
}

List<int> _utf8() => '第一章 开始\n这是正文。\n'.runes
    .expand(
      (r) => r < 0x80
          ? [r]
          : [0xe0 | (r >> 12), 0x80 | ((r >> 6) & 0x3f), 0x80 | (r & 0x3f)],
    )
    .toList();
