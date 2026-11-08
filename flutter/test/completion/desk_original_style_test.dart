import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_layout_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 中央目录比本地文件头可靠：我们写的 ZIP 大小可能写在数据描述符里。
Map<String, List<int>> _zip(List<int> zip) {
  final data = ByteData.sublistView(Uint8List.fromList(zip));
  var end = zip.length - 22;
  while (data.getUint32(end, Endian.little) != 0x06054b50) {
    end--;
  }
  var at = data.getUint32(end + 16, Endian.little);
  final count = data.getUint16(end + 10, Endian.little);
  final files = <String, List<int>>{};
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
    files[name] = method == 0 ? body : ZLibDecoder(raw: true).convert(body);
    at += 46 + nameLength + extra + comment;
  }
  return files;
}

Future<String> _convert(
  PrototypeState state,
  String id,
  String directory,
  String format, {
  required bool original,
}) async {
  final session = LegacyConversionSession(state);
  try {
    final plan = await session.preview(
      ConversionRequest(
        books: [id],
        directory: directory,
        format: format,
        engine: format == 'EPUB'
            ? ''
            : ['AZW3', 'MOBI'].contains(format)
            ? Platform.environment['EASYPUB_TEST_KINDLING']!
            : Platform.environment['EASYPUB_TEST_BOKAI']!,
        generateCover: true,
        runChecks: false,
        keepOriginalEpub: original ? {id} : const {},
      ),
    );
    expect(plan.previewed, true);
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

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  Future<void> until(WidgetTester t, bool Function() ready) async {
    for (var i = 0; i < 600; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (ready()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    fail('界面未就绪');
  }

  testWidgets('原书样式：只有 EPUB 书有这个页签，设置写进本书，成品按它改，KFX 也走得通', (t) async {
    t.view.physicalSize = const Size(1300, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String root, txtId, epubId;
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp('original-style-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final txt = File('$root/样书.txt')
        ..writeAsStringSync('第一章 开始\n　　第一章正文。\n第二章 继续\n　　第二章正文。\n');
      await library.importFiles([txt.path]);
      txtId = state.currentId;
      Directory('$root/first').createSync();
      final first = await _convert(
        state,
        txtId,
        '$root/first',
        'EPUB',
        original: false,
      );
      await library.importFiles([first]);
      epubId = state.currentId;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    var keep = false;
    Widget page(String id) => MaterialApp(
      theme: deskTheme(),
      home: Scaffold(
        body: LayoutPage(
          key: ValueKey(id),
          library: library,
          bookId: id,
          navigation: LayoutNavigationGuard(),
          pickPresetFile: () async => null,
          pickPresetDestination: () async => null,
          importCss: () async => null,
          keepsOriginal: () => keep,
          setKeepsOriginal: (v) => keep = v,
        ),
      ),
    );
    Finder key(String k) => find.byKey(ValueKey(k));

    // TXT 书没有这个页签。
    await t.pumpWidget(page(txtId));
    await until(t, () => find.text('页面与结构').evaluate().isNotEmpty);
    expect(find.text('原书样式'), findsNothing);

    // EPUB 书有，并且写明现在是哪条路径。
    await t.pumpWidget(page(epubId));
    await until(t, () => find.text('原书样式').evaluate().isNotEmpty);
    await t.tap(find.text('原书样式'));
    await t.pump();
    expect(t.widget<Text>(key('layout-original-mode')).data, contains('软件排版'));
    await t.tap(key('layout-original-switch'));
    await t.pump();
    expect(keep, true);
    expect(t.widget<Text>(key('layout-original-mode')).data, contains('保持原格式'));

    // 保持原格式的书，文字页签不再让选字体。
    await t.tap(find.text('文字'));
    await t.pump();
    expect(key('layout-font-original-mode'), findsOneWidget);
    expect(key('layout-font-pick'), findsNothing);
    await t.tap(find.text('原书样式'));
    await t.pump();

    // 勾选立刻保存，输入框点保存。
    await t.tap(key('layout-original-filter-颜色'));
    await until(
      t,
      () =>
          (state.production.settings(epubId)['original_style']
              as Map?)?['filter_css'] !=
          null,
    );
    await t.ensureVisible(key('layout-original-css'));
    await t.enterText(key('layout-original-css'), 'p { line-height: 1.8; }');
    await t.enterText(key('layout-original-margin_left'), '2em');
    await t.tap(key('layout-original-save'));
    await until(
      t,
      () =>
          (state.production.settings(epubId)['original_style']
              as Map?)?['extra_css'] ==
          'p { line-height: 1.8; }',
    );
    final saved = state.production.settings(epubId)['original_style'] as Map;
    expect(saved['filter_css'], ['color']);
    expect(saved['margin_left'], '2em');

    // 写错了不保存，并且说明原因。
    await t.enterText(
      key('layout-original-css'),
      'p { background: url(a.png); }',
    );
    await t.tap(key('layout-original-save'));
    await until(t, () => key('layout-original-error').evaluate().isNotEmpty);
    expect(
      (state.production.settings(epubId)['original_style'] as Map)['extra_css'],
      'p { line-height: 1.8; }',
    );

    // 成品。
    await t.runAsync(() async {
      final dir = Directory('$root/out')..createSync();
      final path = await _convert(
        state,
        epubId,
        dir.path,
        'EPUB',
        original: true,
      );
      final files = _zip(File(path).readAsBytesSync());
      final added = files.keys.firstWhere(
        (n) => n.endsWith('easypub-original-style.css'),
      );
      expect(
        utf8.decode(files[added]!),
        'body { margin-left: 2em !important; }\np { line-height: 1.8; }\n',
      );
      expect(
        files.entries.any(
          (e) =>
              e.key.endsWith('.xhtml') &&
              utf8.decode(e.value).contains('easypub-original-style.css'),
        ),
        true,
      );
      final kfx = Directory('$root/kfx')..createSync();
      expect(
        File(await _convert(state, epubId, kfx.path, 'KFX', original: true))
            .existsSync(),
        true,
      );
    });
    await t.tap(find.text('页面与结构'));
    await t.pump();
    final rewriteSwitch = find.byKey(
      const ValueKey('layout-original-navigation'),
    );
    await t.ensureVisible(rewriteSwitch);
    await t.tap(rewriteSwitch);
    await until(t, () => find.text('目录标题').evaluate().isNotEmpty);
    await until(
      t,
      () =>
          (state.production.settings(epubId)['navigation_options']
              as Map?)?['apply_to_original'] ==
          true,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  test('原格式目录：从原 EPUB 选章、过滤导航，EPUB/AZW3/MOBI/KFX 导出', () async {
    final root = (await Directory(
      '../artifacts',
    ).createTemp('original-navigation-')).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    final txt = File('${root.path}/sample.txt')
      ..writeAsStringSync('第一章 开始\n第一章正文。\n第二章 后记\n第二章正文。\n');
    await library.importFiles([txt.path]);
    final first = Directory('${root.path}/first')..createSync();
    final original = await _convert(
      state,
      state.currentId,
      first.path,
      'EPUB',
      original: false,
    );
    await library.importFiles([original]);
    final id = state.currentId;
    final layout = LegacyLayoutSession(state, id);
    final nav = await layout.originalNavigation();
    final selected = (nav['entries'] as List).last as Map;
    await layout.apply(
      await layout.preview({
        'navigation_options': {
          'apply_to_original': true,
          'toc_title': '原书章节列表',
          'toc_position': 'back',
          'toc_filter': '后记',
          'start': 'specific',
          'original_start': selected['id'],
        },
      }),
    );
    layout.dispose();
    for (final format in ['EPUB', 'AZW3', 'MOBI', 'KFX']) {
      final directory = Directory('${root.path}/$format')..createSync();
      final path = await _convert(
        state,
        id,
        directory.path,
        format,
        original: true,
      );
      if (format == 'EPUB') {
        final files = _zip(await File(path).readAsBytes());
        final originalFiles = _zip(await File(original).readAsBytes());
        expect(files['EPUB/body.xhtml'], originalFiles['EPUB/body.xhtml']);
        final toc = files.entries.singleWhere(
          (e) => e.key.endsWith('easypub-navigation-0.xhtml'),
        );
        expect(utf8.decode(toc.value), contains('原书章节列表'));
        expect(utf8.decode(toc.value), isNot(contains('第二章 后记')));
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
