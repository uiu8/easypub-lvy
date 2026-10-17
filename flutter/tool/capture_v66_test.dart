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
import 'package:easypub_desktop/desk/controls/controls.dart' show deskTheme;
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:easypub_desktop/desk/rules/rules_page.dart';

/// V64 界面截图：检查页“规则”入口、规则页各页签。输出 artifacts/v66-preview/。
void main() {
  testWidgets('截图：规则开关接通', (t) async {
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
      final out = Directory('../artifacts/v66-preview')
        ..createSync(recursive: true);
      final root = (await out.createTemp('data-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({
        'check_after_import': false,
        'automatic_cleanup_pipeline': [
          {'kind': 'join_hard_wraps', 'min_chars': 1, 'mode': 'chinese'},
        ],
      });
      final file = File('$root/雾港来信.txt')
        ..writeAsStringSync(
          '第一章 雾港\n　　港口的雾从傍晚开始往岸上爬，先吞掉了灯塔的底座。\n'
          '【叮！新手礼包已发放。】\n＊＊＊\n'
          '床前明月光，疑是地上霜\n春风又绿江南岸，明月何时照我还。\n'
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
      await File('../artifacts/v66-preview/$name.png')
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

    Finder tab(String title) => find.byKey(
      ValueKey('rules-tab-${ruleGroups.indexWhere((g) => g.$3 == title)}'),
    );
    Finder toggle(String id) => find.byKey(ValueKey(('rule-toggle', id)));

    await t.pumpWidget(
      app(
        RulesPage(
          library: library,
          bookId: id,
          onBack: () {},
          onOpenLocation: (_) {},
          onOpenSettings: (_) {},
        ),
      ),
    );
    await counted();
    for (var i = 0; i < 300; i++) {
      if (t.widget<InkWell>(toggle('cleanup.trim_trailing_spaces')).onTap !=
          null) {
        break;
      }
      await settle(1);
    }
    await shoot('cleanup-affects');

    await t.tap(tab('章节检查'));
    await settle(2);
    await t.tap(toggle('check.number_gap'));
    await t.tap(tab('排版识别'));
    await settle(2);
    await t.tap(find.textContaining('诗词').first);
    await settle(2);
    await t.tap(toggle('layout.verse.five'));
    await settle(2);
    await shoot('pending');

    await t.tap(find.byKey(const ValueKey('rules-preview')));
    for (
      var i = 0;
      i < 300 &&
          find.byKey(const ValueKey('rule-preview-apply')).evaluate().isEmpty;
      i++
    ) {
      await settle(1);
    }
    await settle(3);
    await shoot('preview-dialog');
    await t.tap(find.byKey(const ValueKey('rule-preview-apply')));
    for (
      var i = 0;
      i < 300 && find.textContaining('已应用').evaluate().isEmpty;
      i++
    ) {
      await settle(1);
    }
    await counted();
    await settle(10);
    await shoot('applied');

    await t.tap(
      find.descendant(
        of: find.byKey(const ValueKey('rules-scope')),
        matching: find.text('新书默认'),
      ),
    );
    await settle(10);
    await shoot('global');
    expect(t.takeException(), isNull);
  });
}
