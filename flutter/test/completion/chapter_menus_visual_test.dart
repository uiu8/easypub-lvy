import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/shell/page_menu.dart';
import 'package:easypub_desktop/desk/catalog/composition_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'grouped chapter and page menus fit ordinary windows and large text',
    (t) async {
      final shadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        final root = Directory('../artifacts/chapter-menus-20261008')
          ..createSync(recursive: true);
        late PrototypeState state;
        late LegacyLibraryAdapter lib;
        await t.runAsync(() async {
          for (final font in {
            'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
            'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          }.entries) {
            await (FontLoader(font.key)..addFont(
                  File(font.value)
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
          state = PrototypeState(
            settingsDirectory: (await root.createTemp('settings-'))
                .absolute
                .path,
          );
          lib = LegacyLibraryAdapter(backend: state);
          await lib.load();
          await lib.savePatch({'check_after_import': false});
          await lib.importFiles([
            File('../samples/章节独立场景/S0/缺陷样书.txt').absolute.path,
          ]);
        });
        addTearDown(() {
          lib.dispose();
          state.dispose();
          t.view.resetPhysicalSize();
          t.view.resetDevicePixelRatio();
        });
        final capture = GlobalKey();
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, _) => Scaffold(
                body: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: WorkspacePageMenu(library: lib),
                    ),
                    Expanded(
                      child: ChapterWorkspace(
                        library: lib,
                        bookId: state.currentId,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        Future<void> settle() async {
          for (var i = 0; i < 25; i++) {
            await t.pump(const Duration(milliseconds: 40));
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
        }

        for (final width in [980.0, 720.0]) {
          t.view.physicalSize = Size(width, 720);
          t.view.devicePixelRatio = 1;
          await t.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp.router(
                debugShowCheckedModeBanner: false,
                theme: deskTheme(),
                routerConfig: router,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(width == 720 ? 1.3 : 1),
                  ),
                  child: child!,
                ),
              ),
            ),
          );
          await settle();
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('chapter-content-tabs')),
              matching: find.text('删除正文行'),
            ),
            findsNothing,
          );
          for (final menu in ['更多章节操作', '页面导航']) {
            await t.tap(find.byTooltip(menu));
            await settle();
            expect(
              // R1 起页面导航只列“最近访问”与“当前书”。
              find.text(menu == '页面导航' ? '书籍信息与封面' : '章节结构'),
              findsOneWidget,
            );
            final boundary =
                capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            await t.runAsync(() async {
              final img = await boundary.toImage();
              final bytes = await img.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File(
                '${root.path}/${menu == '页面导航' ? 'pages' : 'chapters'}-${width.toInt()}.png',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
              img.dispose();
            });
            await t.sendKeyEvent(LogicalKeyboardKey.escape);
            await settle();
          }
          final catalog = lib.openCatalog(state.currentId);
          final alignment = await t.runAsync(() async {
            final ref = await catalog.acquire(
              'paste',
              File('../samples/章节独立场景/S0/参考目录.txt').readAsStringSync(),
              declaredTotal: 690,
            );
            catalog.accept(ref);
            return catalog.preview(ref, identityConfirmed: true);
          });
          showDialog<void>(
            context: t.element(find.byType(Scaffold).first),
            builder: (_) => CatalogCompositionDialog(
              session: catalog,
              alignment: alignment!,
            ),
          );
          await settle();
          expect(find.text('另存修订 TXT'), findsOneWidget);
          await t.tap(find.text('已核对所选修改和预览'));
          await t.pumpAndSettle();
          expect(
            t
                .widget<DeskButton>(
                  find.ancestor(
                    of: find.text('另存修订 TXT'),
                    matching: find.byType(DeskButton),
                  ),
                )
                .onPressed,
            isNotNull,
          );
          expect(
            t
                .widget<DeskButton>(
                  find.ancestor(
                    of: find.text('确认应用目录修复'),
                    matching: find.byType(DeskButton),
                  ),
                )
                .onPressed,
            isNull,
          );
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          await t.runAsync(() async {
            final img = await boundary.toImage();
            final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
            File('${root.path}/catalog-${width.toInt()}.png')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
            img.dispose();
          });
          await t.tap(find.byTooltip('关闭组合预览'));
          await settle();
        }
      } finally {
        debugDisableShadows = shadows;
      }
    },
  );
}
