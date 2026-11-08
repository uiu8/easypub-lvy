import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/checks/checks_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:easypub_desktop/desk/rules/rules_page.dart';

/// V64 界面截图：检查页“规则”入口、规则页各页签。输出 artifacts/v64-preview/。
void main() {
  testWidgets('截图：检查页入口与规则页改版', (t) async {
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
      final out = Directory('../artifacts/v64-preview')
        ..createSync(recursive: true);
      final root = (await out.createTemp('data-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港来信.txt')
        ..writeAsStringSync(
          '第一章 雾港\n　　港口的雾从傍晚开始往岸上爬，先吞掉了灯塔的底座。\n'
          '【叮！新手礼包已发放。】\n＊＊＊\n　　船夫收起缆绳。\n'
          '白日依山尽，黄河入海流。\n欲穷千里目，更上一层楼。\n'
          '第二章 下山\n　　天亮了。ＡＢＣ１２３\n'
          '第四章 远航\n　　船离开了码头...\n',
        );
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    Future<void> settle([int n = 20]) async {
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
      await File('../artifacts/v64-preview/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });

    Widget app(Widget child) => RepaintBoundary(
      key: capture,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: deskTheme(),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );

    Future<void> counted() async {
      for (var i = 0; i < 300; i++) {
        await settle(1);
        if (find.textContaining('已统计').evaluate().isNotEmpty) break;
      }
      await settle(5);
    }

    // 检查页：顶栏“规则”按钮与问题类型名链接。
    await t.pumpWidget(
      app(
        BookChecksPage(
          library: library,
          bookId: id,
          onRepair: (_) {},
          onCatalog: () {},
          onChapter: (_) {},
          onCleanup: () {},
          onRules: (_) {},
        ),
      ),
    );
    await settle(10);
    final link = find.byKey(const ValueKey('issue-rule-link'));
    final check = find.widgetWithText(DeskButton, '检查本书');
    for (var i = 0; i < 300 && link.evaluate().isEmpty; i++) {
      if (check.evaluate().isNotEmpty &&
          t.widget<DeskButton>(check.first).onPressed != null) {
        await t.tap(check.first);
        break;
      }
      await settle(1);
    }
    for (var i = 0; i < 300 && link.evaluate().isEmpty; i++) {
      await settle(1);
    }
    await settle(5);
    await shoot('checks');

    Widget rules({String? focus}) => RulesPage(
      key: ValueKey(focus),
      library: library,
      bookId: id,
      focusRule: focus,
      onBack: () {},
      onOpenLocation: (_) {},
      onOpenSettings: (_) {},
    );

    await t.pumpWidget(app(rules()));
    await counted();
    await shoot('rules-cleanup');

    await t.pumpWidget(app(rules(focus: 'check.number_gap')));
    await counted();
    await shoot('rules-checks-focus');

    await t.tap(
      find.byKey(
        ValueKey('rules-tab-${ruleGroups.indexWhere((g) => g.$3 == '排版识别')}'),
      ),
    );
    await settle(3);
    await t.tap(find.textContaining('诗词').first);
    await settle(3);
    await shoot('rules-layout');

    await t.enterText(find.byKey(const ValueKey('rules-search')), '标题');
    await settle(3);
    await shoot('rules-search');
    expect(t.takeException(), isNull);
  });
}
