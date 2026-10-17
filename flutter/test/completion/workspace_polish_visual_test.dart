import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/resource_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/cleanup/cleanup_page.dart';
import 'package:easypub_desktop/desk/cleanup/rule_dialog.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/metadata/book_information_page.dart';
import 'package:easypub_desktop/desk/resources/resources_page.dart';
import 'package:easypub_desktop/desk/resources/resource_position_dialog.dart';

void main() {
  testWidgets(
    'normal windows, draft rules and image anchors after chapter relocation',
    (t) async {
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late File source;
      late List<int> original;
      final evidence = Directory('../artifacts/workspace-polish-20261008');
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        await evidence.create(recursive: true);
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
        final temp = await evidence.createTemp('forms-');
        state = PrototypeState(
          settingsDirectory: '${temp.absolute.path}/settings',
        );
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        source = File('${temp.path}/普通窗口样书.txt')
          ..writeAsStringSync('第一章 开始\n第一段正文，不能改动。\n\n第二章 后续\n第二段正文，应随章节移动。\n');
        original = source.readAsBytesSync();
        expect(
          (await library.importFiles([source.absolute.path])).single.succeeded,
          true,
        );
        final chapters = library.openChapters(state.currentId);
        final tree = await chapters.read(0);
        await chapters.confirm(
          await chapters.preview(
            tree,
            MoveChapter(tree.nodes[1].id, tree.nodes[0].id),
          ),
        );
        final resource = library.openResources(state.currentId);
        final placements = resource as ResourcePlacementSession;
        final reordered = await placements.placementChapters();
        final rows = await placements.placementParagraphs(reordered[1].id, 0);
        expect(reordered[1].title, '第二章 后续');
        expect(rows.rows.first.text, contains('第二段正文'));
        expect(rows.rows.first.originalLine, 5);
        resource.dispose();
        final cleanup = library.openCleanup(state.currentId);
        try {
          await cleanup.preview(cleanup.settings);
        } on api.ApiError catch (error) {
          fail(
            'Moved chapter cleanup preview: ${await api.describeApiError(error: error)}',
          );
        } finally {
          cleanup.dispose();
        }
      });
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final capture = GlobalKey();
      final id = state.currentId;
      Future<void> settle() async {
        for (var n = 0; n < 70; n++) {
          await t.pump(const Duration(milliseconds: 30));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 12)),
          );
          if (n > 12 &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty) {
            break;
          }
        }
        expect(t.takeException(), isNull);
      }

      Future<void> show(String name, Widget child, double width) async {
        t.view.physicalSize = Size(width, 650);
        await t.pumpWidget(
          MaterialApp(
            theme: deskTheme(),
            scrollBehavior: const DeskScrollBehavior(),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 650),
                textScaler: const TextScaler.linear(1.3),
              ),
              child: RepaintBoundary(
                key: capture,
                child: Scaffold(body: child),
              ),
            ),
          ),
        );
        await settle();
        await t.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${evidence.path}/$name-${width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      for (final width in [980.0, 720.0]) {
        await show(
          'metadata',
          BookInformationPage(
            key: UniqueKey(),
            library: library,
            bookId: id,
            navigation: InformationNavigationGuard(),
            pickImage: () async => null,
          ),
          width,
        );
        await show(
          'layout',
          LayoutPage(
            key: UniqueKey(),
            library: library,
            bookId: id,
            navigation: LayoutNavigationGuard(),
            pickPresetFile: () async => null,
            pickPresetDestination: () async => null,
            importCss: () async => null,
          ),
          width,
        );
        await show(
          'cleanup',
          CleanupPage(
            key: UniqueKey(),
            library: library,
            bookId: id,
            navigation: CleanupNavigationGuard(),
            onChecks: () {},
          ),
          width,
        );
        await show(
          'resources',
          ResourcesPage(
            key: UniqueKey(),
            library: library,
            bookId: id,
            pickImage: () async => null,
            pickFolder: () async => null,
            openCss: () {},
            openChapter: (_) {},
          ),
          width,
        );
      }
      Map<String, dynamic>? ruleDraft;
      await show(
        'rule',
        CleanupRuleDialog(
          initial: const {'kind': 'literal_replace'},
          onDraft: (v) => ruleDraft = v,
        ),
        720,
      );
      await t.enterText(
        find.byKey(const ValueKey('cleanup-rule-name')),
        '保留尚未应用的规则',
      );
      expect(ruleDraft!['name'], '保留尚未应用的规则');
      expect(find.text('采用此规则').hitTestable(), findsOneWidget);
      final resource = library.openResources(id);
      await show(
        'position',
        ResourcePositionDialog(session: resource as ResourcePlacementSession),
        720,
      );
      await t.tap(find.text('第二段正文，应随章节移动。'));
      await t.pump();
      expect(
        find.text('使用此位置').hitTestable(),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox());
      resource.dispose();
      expect(source.readAsBytesSync(), original);
      library.dispose();
      state.dispose();
    },
  );
}
