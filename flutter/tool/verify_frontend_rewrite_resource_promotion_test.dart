import 'dart:convert';
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
import 'package:easypub_desktop/desk/resources/resources_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'original EPUB image promotion requires a position and explicit confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = File('../artifacts/r5-kindle-full-resources/sample.epub')
          .absolute;
      final backend = PrototypeState(
        settingsDirectory: Directory(
          '../artifacts/frontend-rewrite/resource-promotion/settings',
        ).absolute.path,
      );
      addTearDown(backend.dispose);
      late List<int> original;
      await tester.runAsync(() async {
        final font = FontLoader('Microsoft YaHei')
          ..addFont(
            File('C:/Windows/Fonts/msyh.ttc')
                .readAsBytes()
                .then(ByteData.sublistView),
          );
        await font.load();
        await (FontLoader('MaterialIcons')..addFont(
              File(
                'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            File(Platform.environment['EASYPUB_TEST_DLL'] ?? '../target/release/easypub_bridge.dll').absolute.path,
          ),
        );
        original = await source.readAsBytes();
        await backend.importBookOutcome(source.path);
      });
      final library = LegacyLibraryAdapter(backend: backend);
      addTearDown(library.dispose);
      final id = backend.currentId;
      final originalInventory = jsonEncode(backend.production.importedResourcesFor(id));
      final count =
          (backend.production.settings(id)['illustrations'] as List).length;
      String? relocationFolder;
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(20),
                child: ResourcesPage(
                  library: library,
                  bookId: id,
                  pickImage: () async => null,
                  pickFolder: () async => relocationFolder,
                  openCss: () {},
                  openChapter: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 200 && !ready(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(
          ready(),
          true,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data)
              .join('\n'),
        );
      }

      await waitFor(() => find.text('EPUB 原图片').evaluate().isNotEmpty);
      await tester.tap(find.text('EPUB 原图片').first);
      await tester.pump();
      expect(find.text('已在插图列表中'), findsOneWidget);
      await tester.tap(find.text('EPUB 原图片').at(1));
      await tester.pump();
      await tester.tap(find.text('作为插图…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('预览变更'));
      await tester.pumpAndSettle();
      expect(find.text('请选择原稿插入行，再将原书图片加入当前插图。'), findsOneWidget);
      final line = find.widgetWithText(TextField, '插在原稿第几行之后（留空为未定位）');
      await tester.enterText(line, '2');
      await tester.tap(find.text('预览变更'));
      await tester.pump();
      await waitFor(() => find.text('确认应用').evaluate().isNotEmpty);
      expect(
        (backend.production.settings(id)['illustrations'] as List).length,
        count,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        (backend.production.settings(id)['illustrations'] as List).length,
        count,
      );
      await tester.tap(find.text('作为插图…'));
      await tester.pumpAndSettle();
      await tester.enterText(line, '2');
      await tester.tap(find.text('预览变更'));
      await tester.pump();
      await waitFor(() => find.text('确认应用').evaluate().isNotEmpty);
      await tester.tap(find.text('确认应用'));
      await tester.pump();
      await waitFor(
        () =>
            (backend.production.settings(id)['illustrations'] as List).length ==
            count + 1,
      );
      expect(jsonEncode(backend.production.importedResourcesFor(id)), originalInventory);
      await waitFor(() => find.text('已在插图列表中').evaluate().isNotEmpty);
      late String beforeRelink;
      await tester.runAsync(() async {
        final root = Directory(
          '../artifacts/frontend-rewrite/resource-promotion',
        );
        await root.create(recursive: true);
        final folder = await root.createTemp('relinked-');
        relocationFolder = folder.absolute.path;
        final session = library.openResources(id);
        final rows = (await session.read()).where((r) => r.editable).toList();
        final copied = <String>{};
        for (final row in rows) {
          if (copied.add(row.path)) {
            final bytes = await File(row.path).readAsBytes();
            final target = File('$relocationFolder/${row.name}');
            await target.writeAsBytes(bytes, flush: true);
            expect(await target.readAsBytes(), bytes);
          }
        }
        beforeRelink = jsonEncode(backend.production.settings(id));
        await expectLater(
          session.relink({
            -1: '$relocationFolder/${rows.first.name}',
            0: '$relocationFolder/missing.png',
          }),
          throwsA(anything),
        );
        expect(jsonEncode(backend.production.settings(id)), beforeRelink);
        final checked = await session.inspectRelink({
          -1: '$relocationFolder/${rows.first.name}',
          0: '$relocationFolder/missing.png',
        });
        expect(checked[-1]!.sha256, rows.first.image!.sha256);
        expect(checked[0], isNull);
        final replacement = File('$relocationFolder/${rows.first.name}');
        final originalReplacement = await replacement.readAsBytes();
        try {
          await replacement.writeAsBytes(
            await File(rows.firstWhere((r) => r.path != rows.first.path).path)
                .readAsBytes(),
            flush: true,
          );
          final different = await session.inspectRelink({-1: replacement.path});
          expect(different[-1]!.sha256, isNot(rows.first.image!.sha256));
        } finally {
          await replacement.writeAsBytes(originalReplacement, flush: true);
        }
        final stale = await session.relink({-1: replacement.path});
        try {
          await replacement.writeAsBytes([0, 1, 2], flush: true);
          await expectLater(session.apply(stale), throwsA(anything));
          expect(jsonEncode(backend.production.settings(id)), beforeRelink);
        } finally {
          await replacement.writeAsBytes(originalReplacement, flush: true);
        }
        session.dispose();
      });
      await tester.tap(find.text('重新定位…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('浏览文件夹'));
      await tester.pumpAndSettle();
      await waitFor(() => find.text('内容一致').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final rendered =
            await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        try {
          final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../artifacts/frontend-rewrite/resource-promotion/relink.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        } finally {
          rendered.dispose();
        }
      });
      await tester.tap(find.text('预览并确认'));
      await tester.pump();
      await waitFor(() => find.text('确认重新定位').evaluate().isNotEmpty);
      expect(jsonEncode(backend.production.settings(id)), beforeRelink);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(jsonEncode(backend.production.settings(id)), beforeRelink);
      await tester.tap(find.text('重新定位…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('浏览文件夹'));
      await tester.pump();
      await waitFor(() => find.text('内容一致').evaluate().isNotEmpty);
      await tester.tap(find.text('预览并确认'));
      await tester.pump();
      await waitFor(() => find.text('确认重新定位').evaluate().isNotEmpty);
      await tester.tap(find.text('确认重新定位'));
      await tester.pump();
      await waitFor(
        () => (backend.production.settings(id)['cover_path'] as String)
            .startsWith(relocationFolder!),
      );
      final beforeItems =
          (jsonDecode(beforeRelink) as Map)['illustrations'] as List;
      final afterItems =
          backend.production.settings(id)['illustrations'] as List;
      expect(afterItems.length, beforeItems.length);
      for (var i = 0; i < afterItems.length; i++) {
        expect(
          (afterItems[i]['path'] as String).startsWith(relocationFolder!),
          true,
        );
        for (final field in ['alt', 'caption', 'source_line']) {
          expect(afterItems[i][field], beforeItems[i][field]);
        }
      }
      await tester.runAsync(() async {
        expect(await source.readAsBytes(), original);
        final path =
            '${source.parent.path}/promotion-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
        expect(
          await backend.saveProjectOutcome(path),
          true,
          reason: backend.projectStatus,
        );
        expect(
          await backend.openProjectOutcome(path),
          true,
          reason: backend.projectStatus,
        );
        expect(
          (backend.production.settings(backend.currentId)['illustrations']
                  as List)
              .length,
          count + 1,
        );
        expect(
          backend.production.settings(backend.currentId)['illustrations'],
          afterItems,
        );
        expect(
          (backend.production.settings(backend.currentId)['cover_path']
                  as String)
              .startsWith(relocationFolder!),
          true,
        );
      });
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
