import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/dialogs.dart';
import 'package:easypub_desktop/desk/layout/book_batch_dialog.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/metadata/book_information_page.dart';
import 'package:easypub_desktop/desk/resources/resources_page.dart';

/// 90×160 蓝色竖图，与 desk_v54_test 相同。
const pagePng =
    'iVBORw0KGgoAAAANSUhEUgAAAFoAAACgCAIAAAADw+wqAAAA6ElEQVR4nO3QMQ0AIADAMJSgBNkI5EMC42gyAUvHXFu3kR98FQ4cOHDgwIEDBw4cfThw4MCBAwcOHDhw9OHAgQMHDhw4cODA0YcDBw4cOHDgwIEDRx8OHDhw4MCBAwcOHH04cODAgQMHDhw4cPThwIEDBw4cOHDgwNGHAwcOHDhw4MCBA0cfDhw4cODAgQMHDhx9OHDgwIEDBw4cOHD04cCBAwcOHDhw4MDRhwMHDhw4cODAgQNHHw4cOHDgwIEDBw4cfThw4MCBAwcOHDhw9OHAgQMHDhw4cODA0YcDBw4cOHDgwLEecRyN+1b2vJkg2QAAAABJRU5ErkJggg==';

/// R5：书籍信息、排版、资源（LAY-140～145、RES-051～053、META-051～052）。
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

  /// 一本有插图（第一章第 2 段之后）的书，另加一本做批量目标。
  Future<(LegacyLibraryAdapter, String)> open(WidgetTester t) async {
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('r5-')).absolute;
      state = PrototypeState(settingsDirectory: '${root.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final book = File('${root.path}/样书.txt')
        ..writeAsStringSync('第一章 开始\n甲文。\n乙文。\n丙文。\n第二章 后续\n丁文。\n');
      final other = File('${root.path}/另一本.txt')
        ..writeAsStringSync('第一章 甲\n正文。\n');
      await library.importFiles([book.path, other.path]);
      final image = File('${root.path}/竖图.png')
        ..writeAsBytesSync(base64Decode(pagePng));
      final id = library.books.value.firstWhere((b) => b.title == '样书').id;
      final resources = library.openResources(id);
      try {
        await resources.apply(
          await resources.change(index: null, path: image.path, sourceLine: 3),
        );
      } finally {
        resources.dispose();
      }
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    return (library, library.books.value.firstWhere((b) => b.title == '样书').id);
  }

  Widget app(Widget child, {double scale = 1}) => MaterialApp(
    theme: deskTheme(),
    builder: (context, page) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: page!,
    ),
    home: Scaffold(body: child),
  );

  Widget layout(LegacyLibraryAdapter library, String id) => LayoutPage(
    library: library,
    bookId: id,
    navigation: LayoutNavigationGuard(),
    pickPresetFile: () async => null,
    pickPresetDestination: () async => null,
    importCss: () async => null,
  );

  test('小预览分页：插图接在所在段后，随正文按原宽、整页插图单独占一页（R5-01）', () async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 90, 160),
      Paint()..color = const Color(0xff336699),
    );
    final pixels = await recorder.endRecording().toImage(90, 160);
    final style = PreviewStyle(
      title: const TextStyle(fontSize: 20),
      body: const TextStyle(fontSize: 16),
      align: TextAlign.justify,
      indent: 32,
      paragraphSpacing: 8,
      titleSpacing: 20,
      padding: const EdgeInsets.all(20),
    );
    final inline = PreviewImage('竖图.png', pixels: pixels, naturalWidth: 90);
    final pages = paginatePreview(
      title: '第一章',
      paragraphs: ['甲', '乙', '丙'],
      style: style,
      page: const Size(400, 600),
      images: {
        1: [inline],
        2: [const PreviewImage('整页.png', layout: 'full_page')],
      },
    );
    final first = pages.first;
    expect(first.map((p) => p.image?.name ?? p.text).toList(), [
      '第一章',
      '甲',
      '乙',
      '竖图.png',
      '丙',
    ]);
    // 整页插图前后换页，自己占一页；读不出的图（没有像素）也照样占位。
    expect(pages[1].single.image?.name, '整页.png');
    expect(pages.length, 2);
  });

  testWidgets('排版小预览画出本章插图，按原宽度（R5-01）', (t) async {
    size(t, const Size(1500, 1000));
    final (library, id) = await open(t);
    await t.pumpWidget(app(layout(library, id)));
    final pageFinder = find.byType(PreviewPage);
    await until(t, () => pageFinder.evaluate().isNotEmpty);
    PreviewImage? found;
    for (var i = 0; i < 6 && found == null; i++) {
      await until(t, () => pageFinder.evaluate().isNotEmpty);
      found = t
          .widget<PreviewPage>(pageFinder)
          .pieces
          .map((p) => p.image)
          .whereType<PreviewImage>()
          .firstOrNull;
      if (found == null) {
        final next = find.text('下一页');
        if (next.evaluate().isEmpty) break;
        await t.tap(next);
        await t.pump();
      }
    }
    expect(found, isNotNull, reason: '第一章的插图应出现在小预览里');
    expect(found!.name, '竖图.png');
    expect(found.naturalWidth, 90);
    expect(found.pixels, isNotNull);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('窄窗大字号时排版页改为“排版设置 / 阅读预览”切换（R5-04）', (t) async {
    size(t, const Size(1100, 800));
    final (library, id) = await open(t);
    await t.pumpWidget(app(layout(library, id), scale: 1.3));
    await until(
      t,
      () => find.byKey(const ValueKey('layout-tabs')).evaluate().isNotEmpty,
    );
    expect(find.text('阅读预览'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app(layout(library, id)));
    await until(
      t,
      () => find.byKey(const ValueKey('layout-tabs')).evaluate().isNotEmpty,
    );
    // 1.0 倍时 1100 宽仍是两栏。
    expect(find.text('阅读预览'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('资源位置写章节和段落，原稿行号另列；替代文本为空时说明用途（R5-05）', (t) async {
    size(t, const Size(1500, 1000));
    final (library, id) = await open(t);
    await t.pumpWidget(
      app(
        ResourcesPage(
          library: library,
          bookId: id,
          pickImage: () async => null,
          pickFolder: () async => null,
          openCss: () {},
          openChapter: (_) {},
        ),
      ),
    );
    await until(t, () => find.textContaining('第 2 段之后').evaluate().isNotEmpty);
    expect(find.text('第一章 开始 · 第 2 段之后'), findsWidgets);
    expect(find.text('原稿第 3 行之后'), findsOneWidget);
    expect(find.textContaining('读屏和图片显示不出时用到'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('应用到多本书：从排版页进来默认勾选排版字段，来源书不作为目标（R5-02、R5-10）', (t) async {
    size(t, const Size(1500, 1000));
    final (library, id) = await open(t);
    await t.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => BookBatchDialog(
                library: library,
                bookId: id,
                initialFields: layoutFields,
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开'));
    await t.pumpAndSettle();
    expect(find.text('已选 ${layoutFields.length} 项字段…'), findsOneWidget);
    expect(find.text('目标书稿 · 1 / 1'), findsOneWidget);
    expect(find.text('来源'), findsOneWidget);
    expect(find.text('同时应用清理规则'), findsOneWidget);
    expect(find.text('封面与元信息 · 排版'), findsNothing);
    // Esc 关闭（R5-03）。
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('应用到多本书'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('DeskDialog：escapeCloses 时以不可点遮罩打开也能 Esc 关闭，忙碌时不关（R5-03）', (
    t,
  ) async {
    Future<void> openWith({required bool escape, bool busy = false}) async {
      await t.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => DeskDialog(
                  title: '弹窗',
                  closeTooltip: '关闭',
                  escapeCloses: escape,
                  busy: busy,
                  child: const Text('内容'),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
    }

    await openWith(escape: true);
    expect(find.text('内容'), findsNothing);
    await openWith(escape: true, busy: true);
    expect(find.text('内容'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await openWith(escape: false);
    expect(find.text('内容'), findsOneWidget, reason: '没开 escapeCloses 的弹窗行为不变');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('书籍信息：语言留空时提示用设置里的默认语言（R5-07）', (t) async {
    size(t, const Size(1500, 1000));
    final (library, id) = await open(t);
    await t.pumpWidget(
      app(
        BookInformationPage(
          library: library,
          bookId: id,
          navigation: InformationNavigationGuard(),
          pickImage: () async => null,
        ),
      ),
    );
    await until(
      t,
      () => find
          .byKey(const ValueKey('information-language'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.text('留空时用设置里的默认语言'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('information-language-settings')),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
