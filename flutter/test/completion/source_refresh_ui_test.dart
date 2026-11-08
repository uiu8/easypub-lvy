import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/library/source_refresh_dialog.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_removal_test.dart' show fixture, NoPicker;

void main() {
  testWidgets(
    'library source refresh can cancel, review and apply at a small window size',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late String id, title, before, originalPath;
      final capture = GlobalKey();
      await t.runAsync(() async {
        for (final entry in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(entry.key)..addFont(
                File(entry.value)
                    .readAsBytes()
                    .then((b) => b.buffer.asByteData()),
              ))
              .load();
        }
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        final f = await fixture();
        state = f.$1;
        library = f.$2;
        id = state.currentId;
        title = library.books.value.firstWhere((b) => b.id == id).title;
        originalPath = state.current.path;
        await File(originalPath).writeAsString('第一章 新正文\n更新后的正文\n第二章 后续\n后续正文');
        before = jsonEncode(state.projectDocument());
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      Future<void> settle({bool Function()? completed}) async {
        for (var i = 0; i < 500; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
          if (!library.projectBusy.value &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              (completed?.call() ?? true)) {
            await t.pumpAndSettle();
            return;
          }
        }
        fail('source refresh did not finish');
      }

      await t.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(),
            home: Scaffold(
              body: LibraryPage(library: library, picker: NoPicker()),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      Future<void> open() async {
        await t.tap(find.byTooltip('书籍操作：$title'));
        await t.pumpAndSettle();
        await t.tap(find.text('刷新来源…'));
        await t.pump();
        await settle();
        expect(find.byType(SourceRefreshDialog), findsOneWidget);
      }

      await open();
      expect(find.textContaining('正文来源已变化'), findsOneWidget);
      expect(
        t
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '采用新正文'),
            )
            .value,
        false,
      );
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(state.projectDocument(), jsonDecode(before));
      await open();
      t.view.physicalSize = const Size(900, 720);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/completion-refresh80-dialog.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      await t.tap(find.text('采用新正文'));
      await t.pumpAndSettle();
      await t.tap(find.text('采用所选信息与新正文'));
      await t.pump();
      await settle();
      expect(find.text('已采用新正文；旧编辑保存在恢复项目中。'), findsOneWidget);
      expect(find.text('复制恢复项目路径'), findsOneWidget);
      expect(library.books.value.length, 2);
      await t.tap(find.text('打开旧书稿项目'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(library.books.value.length, 2);
      await t.tap(find.text('完成'));
      await t.pumpAndSettle();
      expect(find.byType(SourceRefreshDialog), findsNothing);
      await t.runAsync(() async {
        final chapters = await library.openChapters(id).read(0);
        expect(chapters.nodes.map((n) => n.title), ['第一章 新正文', '第二章 后续']);
        expect(await File(originalPath).readAsString(), contains('更新后的正文'));
      });
      await t.tap(find.byTooltip('书籍操作：$title'));
      await t.pumpAndSettle();
      await t.tap(find.text('打开刷新前的书稿…'));
      await t.pumpAndSettle();
      await t.tap(find.text('放弃更改'));
      await t.pump();
      // 项目打开使用原生异步 I/O，页面没有 LinearProgressIndicator；
      // pumpAndSettle 或仅等动画结束不能证明书库已经恢复。
      await settle(completed: () => library.books.value.length == 1);
      expect(library.books.value.length, 1);
      await t.runAsync(() async {
        expect(
          (await library.openChapters(id).read(0)).nodes.first.title,
          '第一章 开始',
        );
      });
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
