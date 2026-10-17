import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/supplemental_page_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:easypub_desktop/desk/metadata/book_information_page.dart';

/// V56 界面截图：书籍信息页“前后附页”卡片、编辑对话框、模板管理。输出 artifacts/v56-preview/。
void main() {
  testWidgets('截图：前后附页', (t) async {
    final capture = GlobalKey();
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      await loadDeskFonts();
      for (final font in {
        'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(font.key)..addFont(
              File(font.value).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
      }
      final out = Directory('../artifacts/v56-preview')
        ..createSync(recursive: true);
      final root = (await out.createTemp('data-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港来信.txt')
        ..writeAsStringSync('第一章 雾起\n港口的雾从傍晚开始往岸上爬。\n第二章 旧码头\n天亮了。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
      final session = library.openSupplementalPages(id);
      for (final content in [
        SupplementalPageContent(
          kind: SupplementalPageKind.copyright,
          title: '版权声明',
          body: '书名：雾港来信\n© 2026 保留所有权利',
          includeToc: true,
        ),
        SupplementalPageContent(
          kind: SupplementalPageKind.dedication,
          body: '献给守夜的人',
        ),
        SupplementalPageContent(
          kind: SupplementalPageKind.afterword,
          title: '写在雾散之后',
          body: '写完最后一章的那天，港口的雾终于散了。\n\n谢谢读到这里的你。',
          includeToc: true,
        ),
      ]) {
        await session.confirm(await session.previewAdd(content));
      }
      session.dispose();
      final templates = library.supplementalTemplates;
      await templates.save(
        await templates.list(),
        name: '我的版权页',
        content: SupplementalPageContent(
          kind: SupplementalPageKind.copyright,
          title: '{书名}版权信息',
          body: '书名：{书名}\n作者：{作者}　译者：{译者}\n© {年份} 保留所有权利',
          includeToc: true,
        ),
      );
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
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
      ),
    );
    Future<void> settle([int n = 30]) async {
      for (var i = 0; i < n; i++) {
        await t.pump(const Duration(milliseconds: 40));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
    }

    Future<void> shoot(String name) => t.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('../artifacts/v56-preview/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });

    await settle();
    await t.scrollUntilVisible(
      find.byKey(const ValueKey('supplemental-card')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await settle(10);
    await t.drag(find.byType(Scrollable).first, const Offset(0, -400));
    await settle(10);
    await shoot('card');
    final first = find.byIcon(Icons.edit_outlined).last;
    await t.tap(first);
    await settle(10);
    await shoot('editor');
    await t.tap(find.byKey(const ValueKey('supplemental-preview')));
    await settle(15);
    await shoot('editor-preview');
    await t.tap(find.byKey(const ValueKey('supplemental-back')));
    await settle(5);
    await t.tap(find.text('取消').last);
    await settle(10);
    await t.tap(find.byKey(const ValueKey('supplemental-manage-templates')));
    await settle(20);
    await shoot('templates');
    expect(t.takeException(), isNull);
  });
}
