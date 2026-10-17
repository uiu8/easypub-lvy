import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/resource_service.dart';
import 'package:easypub_desktop/desk/checks/checks_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/resources/resource_position_dialog.dart';

class _NoPicker extends Fake implements BookFilePicker {}

/// V14：插图错误原因、插入位置按卷折叠、排版预览分页与滚轮、检查页重排、书库书架视图。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  void size(WidgetTester t, Size s) {
    t.view.physicalSize = s;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

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

  Future<void> idle(WidgetTester t) => until(
    t,
    () =>
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty,
  );

  late String root;
  Future<(PrototypeState, LegacyLibraryAdapter)> open(
    WidgetTester t,
    String prefix,
    Map<String, String> books,
  ) async {
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp(prefix)).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      for (final e in books.entries) {
        final file = File('$root/${e.key}.txt')..writeAsStringSync(e.value);
        expect((await library.importFiles([file.path])).single.succeeded, true);
      }
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    return (state, library);
  }

  Widget app(Widget child) => MaterialApp(
    theme: deskTheme(),
    home: Scaffold(body: child),
  );

  const png =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  const volumes =
      '第一卷 起始\n第1章 甲\n甲文一。\n\n乙文。\n第2章 乙\n正文二。\n'
      '第二卷 承接\n第3章 丙\n丙文。\n第4章 丁\n丁文。\n';

  testWidgets('插图：没选图片、格式不对、文件损坏各有具体原因；正常图片可预览并采用（RES-045）', (t) async {
    final (state, library) = await open(t, 'v14-resource-', {'插图': volumes});
    final id = state.currentId;
    await t.runAsync(() async {
      final good = File('$root/good.png')..writeAsBytesSync(base64Decode(png));
      // V24 起 GIF、BMP 可以选；TIFF 仍不支持直接选择（只在导入 EPUB 时转换）。
      final tiff = File('$root/plate.tif')..writeAsBytesSync([73, 73, 42, 0]);
      final broken = File('$root/broken.png')..writeAsStringSync('不是图片');
      final resources = library.openResources(id);
      try {
        Future<String> reason(String path) async {
          try {
            await resources.change(index: null, path: path, sourceLine: 3);
          } on FormatException catch (e) {
            return e.message;
          }
          return '';
        }

        expect(await reason(''), contains('还没有选择图片'));
        expect(await reason(tiff.path), contains('只支持 PNG、JPG、WebP、GIF、BMP'));
        expect(await reason('$root/missing.png'), contains('找不到这张图片'));
        expect(await reason(broken.path), contains('无法读取这张图片'));
        final plan = await resources.change(
          index: null,
          path: good.path,
          sourceLine: 3,
        );
        expect(plan.changed, contains('illustrations'));
        await resources.apply(plan);
        expect(
          (state.production.settings(id)['illustrations'] as List)
              .single['path'],
          good.path,
        );
        expect(await reason(good.path), contains('已在当前插图列表中'));
      } finally {
        resources.dispose();
      }
    });
  });

  testWidgets('选择插入位置：按卷折叠，空行没有选择圈（RES-046/047）', (t) async {
    size(t, const Size(1300, 900));
    final (state, library) = await open(t, 'v14-position-', {'分卷': volumes});
    final resources = library.openResources(state.currentId);
    addTearDown(resources.dispose);
    await t.pumpWidget(
      app(
        ResourcePositionDialog(session: resources as ResourcePlacementSession),
      ),
    );
    await until(t, () => find.text('甲文一。').evaluate().isNotEmpty);
    await idle(t);
    // 默认展开当前（第一）卷；第二卷折叠。
    expect(find.text('第一卷 起始'), findsOneWidget);
    expect(find.text('第1章 甲'), findsWidgets);
    expect(find.text('第二卷 承接'), findsOneWidget);
    expect(find.text('第3章 丙'), findsNothing);
    await t.tap(find.text('第二卷 承接'));
    await t.pump();
    expect(find.text('第3章 丙'), findsOneWidget);
    // 第1章：两段正文各有选择圈，中间的空行只是淡色分隔。
    expect(find.text('空行'), findsOneWidget);
    expect(find.text('（空行）'), findsNothing);
    expect(find.byIcon(Icons.radio_button_off), findsNWidgets(2));
    // 搜索时显示全部匹配章节（不受折叠影响）。
    await t.tap(find.text('第二卷 承接'));
    await t.pump();
    await t.enterText(find.byType(TextField).first, '丁');
    await t.pump();
    expect(find.text('第4章 丁'), findsOneWidget);
    await t.enterText(find.byType(TextField).first, '');
    await t.pump();
    await t.tap(find.text('甲文一。'));
    await t.pump();
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.text('插在“甲文一。”之后'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('排版预览：分页逐页不超出、滚轮翻页、设置区可收起（LAY-100/101）', (t) async {
    size(t, const Size(1500, 1000));
    final body = List.generate(
      90,
      (i) => '第$i段：他抬起头看向远处，雨还在下，街灯在水洼里碎成一片一片。' * 2,
    ).join('\n');
    final (state, library) = await open(t, 'v14-layout-', {
      '长章': '第一章 开始\n$body\n第二章 结束\n尾声\n',
    });
    // 分页结果在绘制时逐页不超出版心（与渲染用同一套 TextPainter）。
    final metrics = readerMetrics(
      const PreviewDeviceChoice(id: 'kpw5'),
      bookScale: 1,
      bookLineHeight: 1.2,
    );
    final style = PreviewStyle(
      title: TextStyle(
        fontSize: metrics.fontPx * 1.3,
        height: metrics.lineRatio,
      ),
      body: TextStyle(fontSize: metrics.fontPx, height: metrics.lineRatio),
      align: TextAlign.justify,
      indent: 2 * metrics.fontPx,
      paragraphSpacing: .5 * metrics.fontPx,
      titleSpacing: 20,
      padding: metrics.padding,
    );
    final device = kindleDevices.firstWhere((k) => k.id == 'kpw5');
    final page = Size(
      device.viewportWidth.toDouble(),
      device.viewportHeight.toDouble(),
    );
    final pages = paginatePreview(
      title: '第一章 开始',
      paragraphs: body.split('\n'),
      style: style,
      page: page,
      locale: const Locale('zh', 'CN'),
    );
    expect(pages.length, greaterThan(3));
    final width = page.width - style.padding.horizontal;
    final height = page.height - style.padding.vertical;
    for (final p in pages) {
      expect(
        PreviewPage.contentHeight(p, style, width, const Locale('zh', 'CN')),
        lessThanOrEqualTo(height + .5),
      );
    }

    await t.pumpWidget(
      app(
        LayoutPage(
          library: library,
          bookId: state.currentId,
          navigation: LayoutNavigationGuard(),
          pickPresetFile: () async => null,
          pickPresetDestination: () async => null,
          importCss: () async => null,
        ),
      ),
    );
    final counter = find.byKey(const ValueKey('layout-preview-pages'));
    await until(t, () => counter.evaluate().isNotEmpty);
    await idle(t);
    await t.pumpAndSettle();
    expect(t.widget<Text>(counter).data, startsWith('第 1 / '));
    // 滚轮在预览上：向下翻到第 2 页，再向上回到第 1 页。
    final wheel = find.byKey(const ValueKey('layout-preview-wheel'));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(pointer.hover(t.getCenter(wheel)));
    await t.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await t.pump();
    expect(t.widget<Text>(counter).data, startsWith('第 2 / '));
    await t.pump(const Duration(milliseconds: 300));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 260)),
    );
    await t.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
    await t.pump();
    expect(t.widget<Text>(counter).data, startsWith('第 1 / '));
    // 收起设置区：预览更宽，可再展开。
    final before = t.getRect(
      find.byKey(const ValueKey('layout-preview-wheel')),
    );
    await t.tap(find.byKey(const ValueKey('layout-settings-collapse')));
    await t.pumpAndSettle();
    final after = t.getRect(find.byKey(const ValueKey('layout-preview-wheel')));
    expect(after.width, greaterThan(before.width + 250));
    await t.tap(find.byKey(const ValueKey('layout-settings-expand')));
    await t.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('layout-settings-collapse')),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('检查页：页签带数量、检查时间、一键修复合并为下拉；旧格式结果识别（CHK-057/058）', (t) async {
    size(t, const Size(1500, 1000));
    final (state, library) = await open(t, 'v14-checks-', {
      '跳号': '第一章 开始\n正文  \n\n\n正文\n第二章 继续\n正文\n第四章 跳号\n正文\n',
    });
    final calls = <String>[];
    await t.pumpWidget(
      app(
        BookChecksPage(
          library: library,
          bookId: state.currentId,
          onRepair: (guided) => calls.add('auto'),
          onCatalog: () => calls.add('catalog'),
          onCatalogRepair: () => calls.add('catalog-repair'),
          onChapter: (_) {},
          onCleanup: () {},
        ),
      ),
    );
    await until(
      t,
      () =>
          find.byKey(const ValueKey('checks-checked-at')).evaluate().isNotEmpty,
    );
    // 页签：标题后带数量；不再有单独的状态标签行。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('checks-tab-chapters')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('检查于 今天'), findsOneWidget);
    expect(find.byKey(const ValueKey('checks-catalog-repair')), findsNothing);
    await t.tap(find.byKey(const ValueKey('checks-repair-menu')));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('按参考目录修复…'), findsOneWidget);
    expect(find.text('依据目录核对…'), findsOneWidget);
    await t.tap(find.text('依据目录核对…'));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(calls, ['catalog']);
    // 文本清理页签：按规则分组显示，不出现旧的文字清单。
    await t.tap(find.byKey(const ValueKey('checks-tab-cleanup')));
    await t.pump();
    expect(find.byKey(const ValueKey('cleanup-findings')), findsOneWidget);
    expect(find.textContaining('前：'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    // 旧格式：没有检查时间，或清理只有文字清单。V19 起这一判断只在读取没有版本号的
    // 报告时做一次（CHK-060），页面看版本号。
    Map<String, dynamic> saved(List<String> items, {String? checkedAt}) => {
      'guard': 'g',
      'evidence': '',
      'safe': 0,
      'checked_at': ?checkedAt,
      'domains': [
        {
          'id': 'cleanup',
          'title': '文本清理',
          'status': '',
          'detail': '',
          'items': items,
        },
      ],
    };
    expect(
      isLegacyCheckReport(
        BookCheckReport.fromJson(saved(['有效稿第 3 行 · 基础清理变更'])),
      ),
      true,
    );
    expect(
      isLegacyCheckReport(
        BookCheckReport.fromJson(
          saved(['有效稿第 3 行 · 基础清理变更'], checkedAt: '2026-10-12T00:00:00'),
        ),
      ),
      true,
    );
    expect(
      isLegacyCheckReport(
        BookCheckReport.fromJson(saved([], checkedAt: '2026-10-12T00:00:00')),
      ),
      false,
    );
    // 新写入的报告带当前版本号。
    expect(
      isLegacyCheckReport(
        BookCheckReport(
          'g',
          const [CheckDomain('cleanup', '文本清理', '0 处清理建议', '', [])],
          null,
          '',
          0,
          checkedAt: DateTime(2026, 10, 12),
        ),
      ),
      false,
    );
  });

  testWidgets('书库：默认书架视图、大封面、角标、Ctrl 点击与拖动框选、切换列表、详情精简（LIB-101–103）', (
    t,
  ) async {
    size(t, const Size(1500, 1000));
    final (_, library) = await open(t, 'v14-shelf-', {
      '甲书': '第一章 开始\n正文\n第二章 继续\n正文\n第四章 跳号\n正文\n',
      '乙书': '第一章 开始\n正文\n',
      '丙书': '第一章 开始\n正文\n',
    });
    final ids = library.books.value.map((b) => b.id).toList();
    final first = library.books.value.firstWhere((b) => b.title == '甲书').id;
    await t.runAsync(() async {
      final checks = library.openChecks(first);
      try {
        await checks.inspect();
      } finally {
        checks.dispose();
      }
      library.selectBook(first);
    });
    String? revealed;
    await t.pumpWidget(
      app(
        LibraryPage(
          library: library,
          picker: _NoPicker(),
          onRevealSource: (path) async => revealed = path,
        ),
      ),
    );
    await idle(t);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-shelf')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-column-header')), findsNothing);
    // 书架封面：生成封面，宽度至少 130。
    final cover = find.descendant(
      of: find.byKey(ValueKey('library-row-$first')),
      matching: find.byKey(const ValueKey('generated-cover')),
    );
    expect(t.getSize(cover).width, greaterThanOrEqualTo(130));
    // 甲书有待核对：封面角标显示数量。
    final pending = library.books.value
        .firstWhere((b) => b.id == first)
        .pending!;
    expect(
      find.descendant(
        of: find.byKey(ValueKey('library-badge-$first')),
        matching: find.text('${pending.chapters}'),
      ),
      findsOneWidget,
    );
    // 勾选框只在悬停时出现。
    expect(find.byKey(ValueKey('library-check-${ids[1]}')), findsNothing);
    Set<String> checked() => library.selection.value.selected;
    // Ctrl+点击加选。
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.tap(find.byKey(ValueKey('library-row-${ids[1]}')));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(checked(), {ids[1]});
    // 多选进行中：所有书的勾选框都显示。
    expect(find.byKey(ValueKey('library-check-${ids[2]}')), findsOneWidget);
    // 拖动框选：从第一本拖到第三本，三本都加入勾选。
    final drag = await t.startGesture(
      t.getCenter(find.byKey(ValueKey('library-row-${ids[0]}'))),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await t.pump();
    await drag.moveTo(
      t.getCenter(find.byKey(ValueKey('library-row-${ids[1]}'))),
    );
    await t.pump();
    await drag.moveTo(
      t.getCenter(find.byKey(ValueKey('library-row-${ids[2]}'))),
    );
    await t.pump();
    expect(find.byKey(const ValueKey('drag-select-band')), findsOneWidget);
    await drag.up();
    await t.pump();
    expect(checked(), ids.toSet());
    // Esc 清空。
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(checked(), isEmpty);
    // 详情：大封面、编辑章节、状态一行，原文件位置只留文件夹图标。
    expect(
      find.byKey(const ValueKey('book-summary-open-chapters')),
      findsOneWidget,
    );
    expect(find.text('章节问题 ${pending.chapters} 项'), findsOneWidget);
    expect(find.text('最近检查'), findsOneWidget);
    expect(find.text('查看问题 →'), findsOneWidget);
    expect(find.byKey(const ValueKey('book-summary-path')), findsNothing);
    await t.tap(find.byTooltip('打开文件夹'));
    await t.pump();
    expect(revealed, library.books.value.firstWhere((b) => b.id == first).path);
    // 切换到列表视图：表头出现，列表封面 48 宽。
    await t.tap(find.byKey(const ValueKey('library-view-toggle')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-column-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-shelf')), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
