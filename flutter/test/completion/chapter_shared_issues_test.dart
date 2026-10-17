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
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/checks/issue_browser.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'chapter issue tab shares full pages, exact context, navigation and persisted review with read-only source tracing',
    (t) async {
      final shadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        t.view.physicalSize = const Size(2000, 1100);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        late PrototypeState state;
        late LegacyLibraryAdapter library;
        late Directory root;
        late String id;
        late File source;
        late String original;
        await t.runAsync(() async {
          for (final font in {
            'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
            'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          }.entries) {
            await (FontLoader(font.key)..addFont(
                  File(font.value)
                      .readAsBytes()
                      .then((bytes) => bytes.buffer.asByteData()),
                ))
                .load();
          }
          await RustLib.init(
            externalLibrary: ExternalLibrary.open(
              Platform.environment['EASYPUB_TEST_DLL']!,
            ),
          );
          root = (await Directory('../artifacts').createTemp('shared-issues-'))
              .absolute;
          state = PrototypeState(settingsDirectory: '${root.path}/settings');
          library = LegacyLibraryAdapter(backend: state);
          await library.load();
          await library.savePatch({'check_after_import': false});
          original = List.generate(
            80,
            (i) => '第${i * 2 + 1}章 标题$i\n正文内容$i。\n\n',
          ).join();
          source = File('${root.path}/长书.txt')..writeAsStringSync(original);
          expect(
            (await library.importFiles([source.path])).single.succeeded,
            true,
          );
          id = state.currentId;
        });
        addTearDown(() {
          library.dispose();
          state.dispose();
        });
        final session = library.openChapters(id);
        Future<void> settle() async {
          for (var i = 0; i < 300; i++) {
            await t.pump(const Duration(milliseconds: 20));
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 15)),
            );
            if (i > 8 &&
                find.byType(LinearProgressIndicator).evaluate().isEmpty &&
                find.byType(CircularProgressIndicator).evaluate().isEmpty) {
              return;
            }
          }
          fail('Shared issue browser did not settle');
        }

        final capture = GlobalKey();
        await t.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: deskTheme(),
              home: Scaffold(
                body: ChapterWorkspace(
                  library: library,
                  bookId: id,
                  initialIssues: true,
                ),
              ),
            ),
          ),
        );
        await settle();
        for (final width in [1150.0, 690.0]) {
          t.view.physicalSize = Size(width, 680);
          t.platformDispatcher.textScaleFactorTestValue = width < 800 ? 1.3 : 1;
          await settle();
          expect(t.takeException(), isNull);
          await t.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('${root.path}/issue-workspace-${width.toInt()}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        t.platformDispatcher.clearTextScaleFactorTestValue();
        t.view.physicalSize = const Size(2000, 1100);
        await settle();
        await t.tap(find.text('正文').first);
        await settle();
        await t.tap(find.byTooltip('章节菜单').first);
        await t.pumpAndSettle();
        expect(find.text('对比两章正文'), findsOneWidget);
        await t.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${root.path}/chapter-menu.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await t.tapAt(const Offset(1550, 50));
        await t.pumpAndSettle();
        await t.tap(find.text('问题').first);
        await settle();
        expect(find.byType(CheckIssueBrowser), findsOneWidget);
        expect(find.byKey(const ValueKey('check-category')), findsOneWidget);
        expect(find.byTooltip('对照方式'), findsOneWidget);
        expect(find.byTooltip('审阅此项'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('check-category')));
        await t.pumpAndSettle();
        await t.tap(find.textContaining('编号跳跃 (').last);
        await settle();
        t
            .widget<Slider>(find.byKey(const ValueKey('issue-position')))
            .onChangeEnd!(50);
        await settle();
        expect(find.textContaining('问题 51 /'), findsOneWidget);
        late ChapterIssue target;
        await t.runAsync(() async {
          final tree = await session.read(0);
          target = (await session.issues(
            tree,
            50,
            effective: true,
          )).items.first;
        });
        await t.tap(find.text('定位章节'));
        await settle();
        expect(
          find.byKey(ValueKey('tree-node-${target.entryId}')),
          findsOneWidget,
        );
        // Selected target can be on a different native tree page.
        await t.runAsync(() async {
          final tree = await session.read(target.nodeOffset!);
          expect(tree.nodes.any((n) => n.id == target.entryId), true);
        });
        await t.tap(find.text('问题').first);
        await settle();
        expect(
          t
              .widget<DeskChoice<String>>(
                find.byKey(const ValueKey('check-category')),
              )
              .value,
          'number-gap',
        );
        await t.tap(find.byTooltip('对照方式'));
        await t.pumpAndSettle();
        await t.tap(find.text('追溯原稿').last);
        await settle();
        expect(find.text('导入原稿'), findsOneWidget);
        expect(find.text('当前编辑稿'), findsOneWidget);
        expect(find.text('查看修复方案'), findsNothing);
        await t.tap(find.byTooltip('审阅此项'));
        await t.pumpAndSettle();
        await t.tap(find.text('本项已核实正常'));
        await settle();
        expect(find.text('已核实正常'), findsOneWidget);
        await t.tap(find.byTooltip('审阅此项'));
        await t.pumpAndSettle();
        await t.tap(find.text('撤销本项结论'));
        await settle();
        expect(find.text('待核对'), findsOneWidget);
        await t.tap(find.byTooltip('审阅此项'));
        await t.pumpAndSettle();
        await t.tap(find.text('本项已核实正常'));
        await settle();
        await t.tap(find.text('更多'));
        await t.pumpAndSettle();
        await t.tap(find.text('重新读取章节'));
        await settle();
        expect(
          t
              .widget<DeskChoice<String>>(
                find.byKey(const ValueKey('check-category')),
              )
              .value,
          'number-gap',
        );
        expect(find.text('已核实正常'), findsOneWidget);
        late String reviewedId;
        await t.runAsync(() async {
          final tree = await session.read(0);
          final reviewed = <ChapterIssue>[];
          for (var start = 0; ; start += 50) {
            final report = await session.issues(tree, start, effective: true);
            reviewed.addAll(
              report.items.where((i) => i.decision == 'confirmed_normal'),
            );
            if (start + 50 >= report.total) break;
          }
          expect(reviewed.length, 1);
          reviewedId = reviewed.single.id;
        });
        await t.tap(find.byTooltip('对照方式'));
        await t.pumpAndSettle();
        await t.tap(find.text('核对问题').last);
        await settle();
        expect(find.byTooltip('审阅此项'), findsOneWidget);
        await t.tap(find.byTooltip('对照方式'));
        await t.pumpAndSettle();
        await t.tap(find.text('追溯原稿').last);
        await settle();
        expect(find.text('已核实正常'), findsOneWidget);
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() async {
          final path = '${root.path}/reviewed.easypub.json';
          expect((await library.saveProject(path)).succeeded, true);
          expect((await library.openProject(path)).succeeded, true);
          final reopened = library.openChapters(id);
          final tree = await reopened.read(0);
          ChapterIssue? restored;
          for (var start = 0; ; start += 50) {
            final report = await reopened.issues(tree, start, effective: true);
            restored ??= report.items
                .where((i) => i.id == reviewedId)
                .firstOrNull;
            if (start + 50 >= report.total) break;
          }
          expect(restored?.decision, 'confirmed_normal');
          expect(source.readAsStringSync(), original);
        });
        expect(t.takeException(), isNull);
      } finally {
        debugDisableShadows = shadows;
      }
    },
  );
}
