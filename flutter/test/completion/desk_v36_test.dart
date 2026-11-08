import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/kindle_preview_launcher.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/batch_field_dialog.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';

class _Host implements KindlePreviewHost {
  final launched = <Uri>[];
  @override
  String? findEdge() => 'msedge.exe';
  @override
  String? findPlugin() => Directory('../plugins/kindle-preview').absolute.path;
  @override
  Future<void> launch(String edge, Uri url) async => launched.add(url);
}

class _RealHttp extends HttpOverrides {}

/// V36：章节标题样式（LAY-117）与每章单独文件（OUT-081）在排版页、小预览、真机预览中的接通。
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

  test('五种样式的名称、画法与“第 N 章”拆分与 Rust 一致', () {
    expect(headingStyles.keys, [
      'classic',
      'amazon',
      'publisher',
      'two_line',
      'light_novel',
    ]);
    expect(headingLooks.keys.toSet(), headingStyles.keys.toSet());
    expect(headingLooks['classic']!.rule, HeadingRule.dotted);
    expect(headingLooks['amazon']!.rule, HeadingRule.dashed);
    expect(headingLooks['light_novel']!.rule, HeadingRule.solid);
    expect(headingLooks['publisher']!.rule, HeadingRule.none);
    expect(headingLooks['classic']!.scale, closeTo(1.364, .001));
    expect(headingLooks['two_line']!.twoLine, true);
    // 与 Rust chapter_label_end 的测试用例相同。
    expect(chapterLabelEnd('第一章 梦'), '第一章 '.length);
    expect(chapterLabelEnd('  第12回：归来'), '  第12回：'.length);
    expect(chapterLabelEnd('第１０章梦'), '第１０章'.length);
    expect(chapterLabelEnd('第一章'), isNull);
    expect(chapterLabelEnd('第一章   '), isNull);
    expect(chapterLabelEnd('序章 开始'), isNull);
    expect(chapterLabelEnd('第章 无数字'), isNull);
    expect(chapterLabelEnd('第一个人'), isNull);
    expect(batchFieldLabels['heading_style'], '章节标题样式');
    expect(describeBatchValue('heading_style', 'two_line'), '精排两行');
    expect(describeBatchValue('heading_style', 'light_novel'), '日系轻小说');
  });

  test('小预览：标题块计入外边距、内边距与下框，分页不超出版心', () {
    const page = Size(390, 520);
    final paragraphs = List.filled(12, '吕文均坐在出租屋里，盯着桌上那面铜镜看了很久。窗外的雨下了一整夜。');
    PreviewStyle style(String key) => PreviewStyle(
      title: TextStyle(
        fontSize: 18 * headingLooks[key]!.scale,
        fontWeight: FontWeight.w700,
      ),
      body: const TextStyle(fontSize: 18),
      align: TextAlign.justify,
      indent: 36,
      paragraphSpacing: 10,
      titleSpacing: 20,
      padding: const EdgeInsets.all(20),
      heading: headingLooks[key],
      ruleScale: 18 / 17.6,
    );
    final plain = PreviewStyle(
      title: const TextStyle(fontSize: 18 * 1.3),
      body: const TextStyle(fontSize: 18),
      align: TextAlign.justify,
      indent: 36,
      paragraphSpacing: 10,
      titleSpacing: 20,
      padding: const EdgeInsets.all(20),
    );
    // 不传样式时与原来相同：标题后只留 titleSpacing。
    expect(plain.titleBefore, 0);
    expect(plain.titleAfter, 0);
    expect(plain.titleGap, 20);
    final publisher = style('publisher');
    expect(publisher.titleBefore, closeTo(2 * 18 * 1.6, 1e-9));
    expect(publisher.titleGap, closeTo(18 * 1.6, 1e-9));
    final classic = style('classic');
    expect(classic.ruleStroke, greaterThanOrEqualTo(1));
    expect(classic.titleAfter, greaterThan(classic.ruleStroke));
    for (final key in headingLooks.keys) {
      final s = style(key);
      final pages = paginatePreview(
        title: '第一章 我祖上封过神',
        paragraphs: paragraphs,
        style: s,
        page: page,
      );
      expect(pages.first.first.title, true, reason: key);
      for (final p in pages) {
        expect(
          PreviewPage.contentHeight(p, s, page.width - 40),
          lessThanOrEqualTo(page.height - 40 + .5),
          reason: key,
        );
      }
    }
    // 精排两行：标题画成两行，比同字号的一行高。
    final twoLine = style('two_line');
    final oneLine = style('amazon');
    expect(
      PreviewPage.contentHeight(
        const [PreviewPiece('第一章 我祖上封过神', title: true)],
        twoLine,
        350,
      ),
      greaterThan(
        PreviewPage.contentHeight(
          const [PreviewPiece('第一章 我祖上封过神', title: true)],
          oneLine,
          350,
        ),
      ),
    );
  });

  testWidgets('排版页：五个缩略图，默认 EasyPub 经典；点选后自动保存，窄栏不溢出', (t) async {
    t.view.physicalSize = const Size(1100, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v36-layout-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')
        ..writeAsStringSync('第一章 开始\n正文。\n第二章 继续\n正文。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    expect(state.production.settings(id)['heading_style'], 'classic');
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
          ),
        ),
      ),
    );
    final tabs = find.byKey(const ValueKey('layout-tabs'));
    await until(t, () => tabs.evaluate().isNotEmpty);
    await t.tap(find.descendant(of: tabs, matching: find.text('标题')));
    await t.pump();
    final tile = find.byKey(const ValueKey('layout-heading_style-two_line'));
    await until(t, () => tile.evaluate().isNotEmpty);
    for (final key in headingStyles.keys) {
      expect(find.byKey(ValueKey('layout-heading_style-$key')), findsOne);
    }
    expect(find.byType(HeadingSample), findsNWidgets(5));
    final help = t.widget<Tooltip>(
      find.descendant(
        of: find.byKey(const ValueKey('layout-help-heading-style')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(help.message, contains('每章从新的一页开始'));
    expect(help.message, contains('EPUB、AZW3、MOBI、KFX'));
    bool selected(String key) =>
        t
            .widget<Semantics>(
              find
                  .ancestor(
                    of: find.byKey(ValueKey('layout-heading_style-$key')),
                    matching: find.byType(Semantics),
                  )
                  .first,
            )
            .properties
            .selected ==
        true;
    expect(selected('classic'), true);
    expect(selected('two_line'), false);
    await t.ensureVisible(tile);
    await t.pump();
    await t.tap(tile);
    await until(
      t,
      () => state.production.settings(id)['heading_style'] == 'two_line',
    );
    expect(selected('two_line'), true);
    expect(selected('classic'), false);
    expect(t.takeException(), isNull);
  });

  testWidgets('真机预览：按未写回的标题样式生成，按章分文件可跨文件读取，写回本书', (t) async {
    t.view.physicalSize = const Size(1500, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v36-kindle-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')
        ..writeAsStringSync(
          '引言。\n第一章 我祖上封过神\n正文甲。\n第二章 雨夜\n正文乙。\n第三章：铜镜\n正文丙。\n',
        );
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    final id = state.currentId;
    final host = _Host();
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
            kindlePreview: host,
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('layout-kindle-preview'));
    await until(t, () => button.evaluate().isNotEmpty);
    await t.tap(button);
    for (var i = 0; i < 100 && host.launched.isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
    final url = host.launched.single;
    final client = HttpOverrides.runWithHttpOverrides(
      HttpClient.new,
      _RealHttp(),
    );
    addTearDown(() => client.close(force: true));
    Future<(int, String)> get(Uri uri) async {
      final response = await (await client.getUrl(uri)).close();
      return (response.statusCode, await utf8.decodeStream(response));
    }

    Future<Map<String, dynamic>> post(String name, Object body) async {
      final request = await client.postUrl(url.resolve('api/$name'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      expect(response.statusCode, 200, reason: name);
      return jsonDecode(await utf8.decodeStream(response))
          as Map<String, dynamic>;
    }

    Future<void> network(Future<void> Function() action) async {
      var finished = false;
      Object? failure;
      StackTrace? trace;
      await t.runAsync(() async {
        unawaited(() async {
          try {
            await action();
          } catch (error, stack) {
            failure = error;
            trace = stack;
          } finally {
            finished = true;
          }
        }());
      });
      for (var i = 0; i < 3000 && !finished; i++) {
        await t.pump(const Duration(milliseconds: 10));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      if (!finished) fail('本机连接没有在时限内处理完请求');
      if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    }

    await network(() async {
      final (_, raw) = await get(url.resolve('api/state'));
      expect((jsonDecode(raw) as Map)['values']['heading_style'], 'classic');
      // 组件页面有“章节标题”下拉框。
      expect((await get(url)).$2, contains('data-key="heading_style"'));
      final r = await post('render', {
        'values': {'heading_style': 'two_line'},
      });
      expect(r['ok'], true, reason: '${r['message']}');
      final base = '${r['base']}';
      final content = await get(url.resolve('$base${r['content']}'));
      expect(
        content.$2,
        contains('<span class="chapter-label">第一章 </span><br/>我祖上封过神'),
      );
      // 每章一个文件：阅读顺序里有引言与三章各自的文件，组件按它跨文件翻页。
      final opf = await get(url.resolve('${base}package.opf'));
      expect(opf.$1, 200);
      for (final name in [
        'body.xhtml',
        'body-0001.xhtml',
        'body-0002.xhtml',
        'body-0003.xhtml',
      ]) {
        expect(opf.$2, contains('href="$name"'));
        expect((await get(url.resolve('$base$name'))).$1, 200, reason: name);
      }
      final third = await get(url.resolve('${base}body-0003.xhtml'));
      expect(
        third.$2,
        contains('<span class="chapter-label">第三章：</span><br/>铜镜'),
      );
      expect(state.production.settings(id)['heading_style'], 'classic');
      final applied = await post('apply', {
        'values': {'heading_style': 'light_novel'},
      });
      expect(applied['ok'], true, reason: '${applied['message']}');
    });
    for (var i = 0; i < 100; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      if (state.production.settings(id)['heading_style'] == 'light_novel') {
        break;
      }
    }
    expect(state.production.settings(id)['heading_style'], 'light_novel');
    await t.pumpWidget(const SizedBox());
    library.dispose();
    state.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
