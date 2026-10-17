import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/checks/checks_page.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'source_image_refresh_test.dart' show makeImageEpub;

void main() {
  testWidgets(
    'real metadata and resource findings render with reachable targeted actions',
    (t) async {
      t.view.physicalSize = const Size(900, 720);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late String id;
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
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
        final root = (await Directory(
          '../artifacts',
        ).createTemp('check-findings-ui84-')).absolute.path;
        await makeImageEpub('$root/source.epub', updated: false);
        state = PrototypeState(settingsDirectory: '$root/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        expect(
          (await library.importFiles(['$root/source.epub'])).single.succeeded,
          true,
        );
        id = state.currentId;
        final image =
            (state.production.settings(id)['illustrations'] as List).first
                as Map;
        final resources = library.openResources(id);
        await resources.read();
        await resources.apply(
          await resources.change(index: 0, path: image['path'] as String),
        );
        resources.dispose();
        final checks = library.openChecks(id);
        await checks.inspect();
        checks.dispose();
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      String? opened;
      final boundary = GlobalKey();
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: BookChecksPage(
                  library: library,
                  bookId: id,
                  onRepair: (_) {},
                  onCatalog: () {},
                  onChapter: (_) {},
                  onCleanup: () {},
                  onOpenDomain: (domain) => opened = domain,
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      await t.tap(find.text('书籍信息'));
      await t.pump();
      expect(
        find.byKey(const ValueKey('finding-metadata:author')),
        findsOneWidget,
      );
      await t.ensureVisible(find.text('补充信息'));
      await t.tap(find.text('补充信息'));
      expect(opened, 'metadata');
      await t.ensureVisible(find.text('设置封面'));
      await t.tap(find.text('设置封面'));
      expect(opened, 'cover');
      await t.tap(find.text('图片资源'));
      await t.pump();
      expect(find.text('第 1 张插图未设置位置'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('finding-resource:0:unplaced')),
        findsOneWidget,
      );
      await t.ensureVisible(find.text('处理资源').first);
      await t.tap(find.text('处理资源').first);
      expect(opened, 'resources');
      expect(t.takeException(), isNull);
      await t.pump();
      await t.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/completion-check84-findings-ui.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await t.pumpWidget(const SizedBox());
    },
  );
}
