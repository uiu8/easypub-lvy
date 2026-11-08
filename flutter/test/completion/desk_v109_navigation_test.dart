import 'dart:io';

import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/page_parts.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _NoPicker extends Fake implements BookFilePicker {}

/// V109：左栏开关与合并——概览默认收起、检查在章节上面、清理叫“文本”、
/// 图片与资源并进书籍信息、记录并进任务（顶部窄条切换）；设置里可打开概览、收起文件夹。
void main() {
  testWidgets('左栏开关与合并页的顶部切换条', (t) async {
    t.view.physicalSize = const Size(1500, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    late LegacyLibraryAdapter library;
    late PrototypeState state;
    late String bookId;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final tmp = await Directory('../artifacts')
          .createTemp('v109-navigation-');
      state = PrototypeState(
        settingsDirectory: '${tmp.absolute.path}/settings',
      );
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('${tmp.absolute.path}/山海之间.txt')
        ..writeAsStringSync('第一章 远行\n山路很长。\n\n第二章 归来\n海风很轻。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      bookId = library.books.value.single.id;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    library.selectBook(bookId);
    Future<void> settle() async {
      for (var i = 0; i < 60; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
      }
    }

    await t.pumpWidget(RewriteApp(library: library, picker: _NoPicker()));
    await settle();
    final rail = find.byKey(const ValueKey('desk-rail'));
    List<String> labels() => [
      for (final e
          in find
              .descendant(of: rail, matching: find.byType(Semantics))
              .evaluate())
        if ((e.widget as Semantics).properties.label case final l?) l,
    ];
    final names = labels();
    expect(names, isNot(contains('概览')), reason: '概览默认收起');
    expect(names, isNot(contains('图片与资源')));
    expect(names, isNot(contains('记录')));
    expect(names, contains('文本'));
    expect(names, contains('文件夹'));
    expect(names.indexOf('检查与修复'), lessThan(names.indexOf('章节')));

    final router = GoRouter.of(
      t.element(find.byKey(const ValueKey('workspace-output-bar'))),
    );
    final book = Uri.encodeComponent(bookId);
    // 书籍信息：顶部窄条切到图片与资源，左栏仍点亮“书籍信息”。
    router.go('/books/$book/information');
    await settle();
    expect(find.byKey(const ValueKey('page-switcher')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey(('page-switcher', '图片与资源'))));
    await settle();
    expect(
      GoRouter.of(t.element(find.byKey(const ValueKey('page-switcher'))))
          .routerDelegate
          .currentConfiguration
          .uri
          .path,
      '/books/$book/resources',
    );
    // 任务：窄条有任务、转换历史、修改记录；页头不再重复“转换历史”按钮。
    router.go('/tasks');
    await settle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('page-switcher')),
        matching: find.text('修改记录'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(DeskPageHeader),
        matching: find.text('转换历史'),
      ),
      findsNothing,
    );
    await t.tap(find.byKey(const ValueKey(('page-switcher', '记录'))));
    await settle();
    expect(find.text('变更记录'), findsWidgets);
    // 页面不在左栏时用 Ctrl+K 或地址仍能打开：概览页本身照常可用。
    router.go('/books/$book/overview');
    await settle();
    expect(t.takeException(), isNull);

    // 设置：打开概览、收起文件夹。
    await t.runAsync(
      () => library.savePatch({
        'nav_hidden_pages': ['folders'],
      }),
    );
    await settle();
    // 图片自动转换：默认开，不带标记；关掉后生成请求带上“保留原图”。
    expect(
      state.publicationRequest(bookId),
      isNot(contains('keep_original_images')),
    );
    await t.runAsync(() => library.savePatch({'convert_kindle_images': false}));
    expect(state.publicationRequest(bookId)['keep_original_images'], true);
    final after = labels();
    expect(after, contains('概览'));
    expect(after, isNot(contains('文件夹')));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
