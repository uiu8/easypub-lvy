import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/checks/issue_browser.dart';

import 'library_removal_test.dart' show NoPicker;

void main() {
  testWidgets(
    'normal windows keep chapter content readable and dropped files reach native import',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(980, 700);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late File source;
      final root = Directory('../artifacts/layout-window-20261008');
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        for (final font in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(font.key)..addFont(
                File(font.value)
                    .readAsBytes()
                    .then((v) => v.buffer.asByteData()),
              ))
              .load();
        }
        final data = await root.createTemp('normal-window-');
        state = PrototypeState(
          settingsDirectory: '${data.absolute.path}/settings',
        );
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        source = File('${data.absolute.path}/普通窗口长篇示例.txt')
          ..writeAsStringSync(
            List.generate(
              30,
              (i) => '第${i * 2 + 1}章 很长的章节标题用于检查普通窗口布局\n　　这是一段正文。\n\n',
            ).join(),
          );
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final capture = GlobalKey();
      Widget app(Widget child) => MaterialApp(
        theme: deskTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            size: t.view.physicalSize,
            textScaler: TextScaler.linear(1.3),
          ),
          child: RepaintBoundary(
            key: capture,
            child: Scaffold(body: child),
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 120; i++) {
          await t.pump(const Duration(milliseconds: 30));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          if (i > 8 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            return;
          }
        }
        fail('native UI did not settle');
      }

      Future<void> shot(String name) async {
        expect(t.takeException(), isNull);
        await t.runAsync(() async {
          final img =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await img.toByteData(format: ui.ImageByteFormat.png);
          await File('${root.path}/$name.png')
              .writeAsBytes(data!.buffer.asUint8List());
          img.dispose();
        });
      }

      await t.pumpWidget(
        app(LibraryPage(library: library, picker: NoPicker())),
      );
      final drop = t.widget<DropTarget>(find.byType(DropTarget));
      drop.onDragDone!(
        DropDoneDetails(
          files: [DropItemFile(source.path)],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await settle();
      expect(library.books.value.length, 1);
      ScaffoldMessenger.of(t.element(find.byType(LibraryPage)))
          .clearSnackBars();
      await t.pumpAndSettle();
      await t.pumpWidget(
        app(
          ChapterWorkspace(
            library: library,
            bookId: state.currentId,
            initialIssues: true,
            onRepair: (_) {},
          ),
        ),
      );
      await settle();
      // V2c：问题浏览器宽于 760 时队列常驻，980 宽窗口下队列与详情并排，不需要“返回问题列表”。
      expect(find.byKey(const ValueKey('check-issue-list')), findsOneWidget);
      expect(find.byTooltip('返回问题列表'), findsNothing);
      await shot('chapters-980-list');
      await t.tap(
        find
            .descendant(
              of: find.byType(CheckIssueBrowser),
              matching: find.byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(
                      'check-issue-',
                    ) &&
                    (w.key! as ValueKey<String>).value != 'check-issue-list',
              ),
            )
            .first,
      );
      await settle();
      expect(find.byKey(const ValueKey('check-issue-list')), findsOneWidget);
      await shot('chapters-980-detail');
      await t.tap(find.text('正文').first);
      await settle();
      await t.tap(find.byTooltip('章节设置'));
      await t.pumpAndSettle();
      expect(find.byTooltip('关闭章节设置'), findsOneWidget);
      await t.tap(find.byTooltip('关闭章节设置'));
      await t.pumpAndSettle();
      t.view.physicalSize = const Size(760, 620);
      await t.pumpWidget(
        app(
          ChapterWorkspace(
            library: library,
            bookId: state.currentId,
            initialIssues: true,
            onRepair: (_) {},
          ),
        ),
      );
      await settle();
      await shot('chapters-760');
      t.view.physicalSize = const Size(980, 700);
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
      await settle();
      await shot('layout-980');
    },
  );
}
