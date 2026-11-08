import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/metadata/book_information_page.dart';

/// V56：书籍信息页“前后附页”卡片与模板管理（META-048、META-049），真实 DLL。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('添加、编辑、跨组拖动（一步历史）、删除；模板新建并套用，占位符换成本书信息', (t) async {
    t.view.physicalSize = const Size(1100, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late File file;
    late List<int> original;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v56-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      file = File('$root/雾港来信.txt')
        ..writeAsStringSync('第一章 雾起\n正文甲。\n第二章 旧码头\n正文乙。\n');
      original = file.readAsBytesSync();
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    List<Map> pages() =>
        ((state.production.settings(id)['supplemental_pages'] as List?) ??
                const [])
            .cast<Map>();
    int steps() =>
        ((state.production.histories[id]?['states'] as List?) ?? const [])
            .length;

    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 600; i++) {
        await t.pump(const Duration(milliseconds: 20));
        if (ready()) return;
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      fail('界面未就绪');
    }

    Future<void> tap(Finder finder) async {
      await t.ensureVisible(finder);
      await t.pump();
      await t.tap(finder);
      await t.pump();
    }

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: BookInformationPage(
            library: library,
            bookId: id,
            navigation: InformationNavigationGuard(),
            pickImage: () async => null,
          ),
        ),
      ),
    );
    final card = find.byKey(const ValueKey('supplemental-card'));
    await t.scrollUntilVisible(
      card,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await until(() => find.text('暂无').evaluate().length == 2);

    // 添加后记：预览不写入，确认后写入正文后。
    await tap(find.byKey(const ValueKey('supplemental-add')));
    await tap(find.byKey(const ValueKey(('supplemental-add', 'afterword'))));
    await until(
      () => find
          .byKey(const ValueKey('supplemental-title'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      t
          .widget<TextField>(find.byKey(const ValueKey('supplemental-title')))
          .controller!
          .text,
      '后记',
    );
    await t.enterText(
      find.byKey(const ValueKey('supplemental-body')),
      '写给读者的话。',
    );
    await t.pump();
    await tap(find.byKey(const ValueKey('supplemental-preview')));
    await until(
      () => find
          .byKey(const ValueKey('supplemental-preview-body'))
          .evaluate()
          .isNotEmpty,
    );
    expect(pages(), isEmpty, reason: '预览不写入');
    expect(find.textContaining('正文后第 1 条'), findsOneWidget);
    await tap(find.byKey(const ValueKey('supplemental-confirm')));
    await until(() => pages().length == 1);
    final afterword = pages().single['id'] as String;
    expect(pages().single['content']['position'], 'back');
    await until(
      () => find
          .byKey(ValueKey(('supplemental-row', afterword)))
          .evaluate()
          .isNotEmpty,
    );

    // 编辑：改标题。
    await tap(find.byKey(ValueKey(('supplemental-edit', afterword))));
    await until(
      () => find
          .byKey(const ValueKey('supplemental-title'))
          .evaluate()
          .isNotEmpty,
    );
    await t.enterText(
      find.byKey(const ValueKey('supplemental-title')),
      '写在雾散之后',
    );
    await tap(find.byKey(const ValueKey('supplemental-preview')));
    await until(
      () => find
          .byKey(const ValueKey('supplemental-confirm'))
          .evaluate()
          .isNotEmpty,
    );
    await tap(find.byKey(const ValueKey('supplemental-confirm')));
    await until(() => pages().single['content']['title'] == '写在雾散之后');

    // 跨组拖动：拖到“正文前”分组，出现确认条；确认后位置改为正文前，只多一步历史。
    final before = steps();
    final handle = find.byKey(ValueKey(('supplemental-drag', afterword)));
    await until(() => handle.evaluate().isNotEmpty);
    await t.ensureVisible(handle);
    await t.pump();
    final target = t.getCenter(
      find.byKey(const ValueKey(('supplemental-group', '#front'))),
    );
    final gesture = await t.startGesture(t.getCenter(handle));
    await t.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(
        Offset(0, (target.dy + 16 - t.getCenter(handle).dy) / 12),
      );
      await t.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await t.pump(const Duration(milliseconds: 400));
    final confirmOrder = find.byKey(
      const ValueKey('supplemental-order-confirm'),
    );
    await until(
      () =>
          confirmOrder.evaluate().isNotEmpty &&
          t.widget<DeskButton>(confirmOrder).onPressed != null,
    );
    expect(pages().single['content']['position'], 'back', reason: '确认前不写入');
    await tap(confirmOrder);
    await until(() => pages().single['content']['position'] == 'front');
    expect(steps(), before + 1, reason: '改位置与排序是一步历史');

    // 删除：确认框后删除。
    await until(
      () => find
          .byKey(ValueKey(('supplemental-delete', afterword)))
          .evaluate()
          .isNotEmpty,
    );
    await tap(find.byKey(ValueKey(('supplemental-delete', afterword))));
    await until(
      () => find
          .byKey(const ValueKey('supplemental-delete-confirm'))
          .evaluate()
          .isNotEmpty,
    );
    await tap(find.byKey(const ValueKey('supplemental-delete-confirm')));
    await until(() => pages().isEmpty);

    // 模板：新建、点选插入占位符、保存；从模板添加，书名被替换。
    await tap(find.byKey(const ValueKey('supplemental-manage-templates')));
    await until(
      () => find
          .byKey(const ValueKey('supplemental-template-name'))
          .evaluate()
          .isNotEmpty,
    );
    final templateBody = find.byKey(
      const ValueKey('supplemental-template-body'),
    );
    // 列表读完后编辑区填入新建模板的示例正文。
    await until(
      () => t.widget<TextField>(templateBody).controller!.text.isNotEmpty,
    );
    await t.enterText(
      find.byKey(const ValueKey('supplemental-template-name')),
      '我的版权页',
    );
    await t.enterText(
      find.byKey(const ValueKey('supplemental-template-body')),
      '书名：',
    );
    await tap(find.byKey(const ValueKey(('supplemental-placeholder', '{书名}'))));
    expect(
      t
          .widget<TextField>(
            find.byKey(const ValueKey('supplemental-template-body')),
          )
          .controller!
          .text,
      '书名：{书名}',
    );
    await tap(find.byKey(const ValueKey('supplemental-template-save')));
    await until(() => find.text('已保存模板').evaluate().isNotEmpty);
    final template = (await t.runAsync(
      () => library.supplementalTemplates.list(),
    ))!.templates.single;
    expect(template.name, '我的版权页');
    await t.tap(find.byTooltip('关闭').last);
    await t.pump();
    await until(
      () => find
          .byKey(const ValueKey('supplemental-template-name'))
          .evaluate()
          .isEmpty,
    );
    await tap(find.byKey(const ValueKey('supplemental-template-add')));
    final item = find.byKey(ValueKey(('supplemental-template', template.id)));
    await until(() => item.evaluate().isNotEmpty);
    await tap(item);
    await until(
      () => find
          .byKey(const ValueKey('supplemental-template-confirm'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.text('书名：雾港来信'), findsOneWidget, reason: '预览已替换占位符');
    expect(pages(), isEmpty);
    await tap(find.byKey(const ValueKey('supplemental-template-confirm')));
    await until(() => pages().length == 1);
    expect(pages().single['content']['body'], '书名：雾港来信');
    expect(pages().single['content']['kind'], 'copyright');
    expect(file.readAsBytesSync(), original);
    expect(t.takeException(), isNull);
  });
}
