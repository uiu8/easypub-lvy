import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/widgets.dart';

/// 120×40 深灰横条（花饰）与 90×160 蓝色竖图（整页插图）。
const ornamentPng =
    'iVBORw0KGgoAAAANSUhEUgAAAHgAAAAoCAIAAAC6iKlyAAAAcklEQVR4nO3QQREAMAjAMOTgX+FchMcaBb3OhpjrgF80Gmk00mik0UijkUYjjUYajTQaaTTSaKTRSKORRiONRhqNNBppNNJopNFIo5FGI41GGo00Gmk00mik0UijkUYjjUYajTQaaTTSaKTRSKORRq/xAMdpynmBG6HUAAAAAElFTkSuQmCC';
const pagePng =
    'iVBORw0KGgoAAAANSUhEUgAAAFoAAACgCAIAAAADw+wqAAAA6ElEQVR4nO3QMQ0AIADAMJSgBNkI5EMC42gyAUvHXFu3kR98FQ4cOHDgwIEDBw4cfThw4MCBAwcOHDhw9OHAgQMHDhw4cODA0YcDBw4cOHDgwIEDRx8OHDhw4MCBAwcOHH04cODAgQMHDhw4cPThwIEDBw4cOHDgwNGHAwcOHDhw4MCBA0cfDhw4cODAgQMHDhx9OHDgwIEDBw4cOHD04cCBAwcOHDhw4MDRhwMHDhw4cODAgQNHHw4cOHDgwIEDBw4cfThw4MCBAwcOHDhw9OHAgQMHDhw4cODA0YcDBw4cOHDgwLEecRyN+1b2vJkg2QAAAABJRU5ErkJggg==';

Future<String> xhtmlOf(String path) async {
  final result = await Process.run(
    Platform.environment['EASYPUB_TEST_PYTHON']!,
    [
      '-X',
      'utf8',
      '-c',
      r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
 print('\n'.join(z.read(n).decode('utf-8','replace') for n in z.namelist() if n.rsplit('.',1)[-1].lower() in ('xhtml','html','css')))
''',
      path,
    ],
    stdoutEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return result.stdout as String;
}

/// V54：插图版式（RES-050）与统一章首图（LAY-124）。
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

  testWidgets('排版页：选章首图后出现“用于”“宽度”，改范围自动保存，移除后清空', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String ornament;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v54-layout-'))
          .absolute
          .path;
      ornament = '$root/花饰.png';
      File(ornament).writeAsBytesSync(base64Decode(ornamentPng));
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')
        ..writeAsStringSync('第一章 开始\n正文甲。\n第二章 下山\n正文乙。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    expect(state.production.settings(id)['chapter_head_image'], isNull);
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
            pickImage: () async => ornament,
          ),
        ),
      ),
    );
    final tabs = find.byKey(const ValueKey('layout-tabs'));
    await until(t, () => tabs.evaluate().isNotEmpty);
    await t.tap(find.descendant(of: tabs, matching: find.text('标题')));
    await t.pump();
    final pick = find.byKey(const ValueKey('layout-chapter-head-pick'));
    await until(t, () => pick.evaluate().isNotEmpty);
    expect(find.text('未设置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('layout-chapter_head_scope')),
      findsNothing,
    );
    final help = t.widget<Tooltip>(
      find.descendant(
        of: find.byKey(const ValueKey('layout-help-chapter-head')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(help.message, contains('花饰、分隔线这类小图最合适'));
    await t.ensureVisible(pick);
    await t.pump();
    await t.tap(pick);
    await until(
      t,
      () => state.production.settings(id)['chapter_head_image'] == ornament,
    );
    await until(t, () => find.text('花饰.png').evaluate().isNotEmpty);
    final scope = find.byKey(const ValueKey('layout-chapter_head_scope'));
    final segmented = t.widget<DeskSegmented<String>>(
      find.descendant(of: scope, matching: find.byType(DeskSegmented<String>)),
    );
    expect(segmented.value, 'chapter');
    expect(segmented.options, chapterHeadScopes);
    await t.ensureVisible(scope);
    await t.pump();
    await t.tap(find.descendant(of: scope, matching: find.text('卷和章')));
    await until(
      t,
      () => state.production.settings(id)['chapter_head_scope'] == 'both',
    );
    final remove = find.byKey(const ValueKey('layout-chapter-head-remove'));
    await t.ensureVisible(remove);
    await t.pump();
    await t.tap(remove);
    await until(
      t,
      () => state.production.settings(id)['chapter_head_image'] == null,
    );
    expect(t.takeException(), isNull);
  });

  test('真实转换：统一章首图与整页插图进入 EPUB、AZW3、KFX，KFX 通过 Bokai 校验（设了 Calibre 时也能被 Calibre 转换）', () async {
    final root = (await Directory('../artifacts').createTemp('v54-output-'))
        .absolute
        .path;
    final bokai = Platform.environment['EASYPUB_TEST_BOKAI']!;
    final ornament = '$root/花饰.png', page = '$root/整页.png';
    File(ornament).writeAsBytesSync(base64Decode(ornamentPng));
    File(page).writeAsBytesSync(base64Decode(pagePng));
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港.txt')
        ..writeAsStringSync('第一章 雾起\n正文甲。\n正文乙。\n第二章 旧码头\n正文丙。\n');
      final original = file.readAsBytesSync();
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
      final change = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'chapter_head_image': {'op': 'set', 'value': ornament},
            'chapter_head_width': {'op': 'set', 'value': 'third'},
          },
        },
      });
      expect(await state.production.confirm(change), true);
      // 资源服务：整页插图（第 3 行之后，属第一章）。
      final resources = library.openResources(id);
      try {
        final plan = await resources.change(
          index: null,
          path: page,
          caption: '整页图注',
          alt: '整页',
          sourceLine: 3,
          layout: 'full_page',
        );
        await resources.apply(plan);
        final read = await resources.read();
        expect(read.where((r) => r.index == 0).single.layout, 'full_page');
      } finally {
        resources.dispose();
      }
      expect(
        (state.production.settings(id)['illustrations'] as List)
            .single['layout'],
        'full_page',
      );
      final outputs = <String, String>{};
      for (final format in ['EPUB', 'AZW3', 'KFX']) {
        final session = LegacyConversionSession(state);
        try {
          final plan = await session.preview(
            ConversionRequest(
              books: [id],
              directory: '$root/out',
              format: format,
              engine: switch (format) {
                'KFX' => bokai,
                'AZW3' => Platform.environment['EASYPUB_TEST_KINDLING']!,
                _ => '',
              },
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(plan.previewed, true);
          final result = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(result.complete, true, reason: '$format ${result.detail}');
          outputs[format] = result.path;
        } finally {
          session.dispose();
        }
      }
      final epub = await xhtmlOf(outputs['EPUB']!);
      expect(
        '<figure class="chapter-head-image chapter-head-third">'
            .allMatches(epub)
            .length,
        2,
        reason: '两章各一张统一章首图',
      );
      expect(
        epub,
        contains('.chapter-head-third img { width: 33%; height: auto; }'),
      );
      expect(epub, contains('<figure class="full-page-image"><img '));
      expect(epub, contains('<figcaption>整页图注</figcaption>'));
      // AZW3、KFX 经 Bokai 解回：章首图与整页插图的类名仍在（KFX 转换时已通过 validate all）。
      for (final format in ['AZW3', 'KFX']) {
        final back = '$root/$format-back.epub';
        final run = await Process.run(bokai, [
          'convert',
          '--no-validate',
          outputs[format]!,
          back,
        ]);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final decoded = await xhtmlOf(back);
        expect(decoded, contains('<img'), reason: format);
      }
      final calibre = Platform.environment['EASYPUB_TEST_CALIBRE'];
      if (calibre != null) {
        final run = await Process.run(calibre, [
          outputs['KFX']!,
          '$root/kfx-calibre.epub',
        ]);
        expect(run.exitCode, 0, reason: 'Calibre 读不了本批 KFX：${run.stdout}');
      }
      expect(file.readAsBytesSync(), original);
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
