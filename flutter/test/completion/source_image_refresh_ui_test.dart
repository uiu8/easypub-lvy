import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/library/source_refresh_dialog.dart';
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
    'resource-only refresh offers independent image adoption and keeps unchecked metadata',
    (t) async {
      t.view.physicalSize = const Size(900, 720);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late String id;
      final capture = GlobalKey();
      await t.runAsync(() async {
        for (final e in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(e.key)..addFont(
                File(e.value).readAsBytes().then((b) => b.buffer.asByteData()),
              ))
              .load();
        }
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        final root = (await Directory(
          '../artifacts',
        ).createTemp('source-image-ui81-')).absolute.path;
        final path = '$root/source.epub';
        await makeImageEpub(path, updated: false);
        state = PrototypeState(settingsDirectory: '$root/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        expect((await library.importFiles([path])).single.succeeded, true);
        id = state.currentId;
        await makeImageEpub(path, updated: true);
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      Future<void> settle() async {
        for (var i = 0; i < 500; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
            await t.pumpAndSettle();
            return;
          }
        }
        fail('image refresh did not finish');
      }

      await t.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(),
            home: Scaffold(
              body: SourceRefreshDialog(service: library, bookId: id),
            ),
          ),
        ),
      );
      await settle();
      expect(find.text('采用新正文'), findsNothing);
      expect(find.text('更新来源插图'), findsOneWidget);
      expect(
        t
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '更新来源插图'),
            )
            .value,
        false,
      );
      expect(state.production.settings(id)['illustrations'], hasLength(3));
      await t.tap(find.text('更新来源插图'));
      await t.pumpAndSettle();
      await t.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/completion-refresh81-images-ui.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      await t.tap(find.text('采用所选信息与插图'));
      await t.pump();
      await settle();
      expect(find.text('已更新来源插图，正文与章节编辑保留。'), findsOneWidget);
      expect(state.production.settings(id)['illustrations'], hasLength(4));
      expect(state.production.settings(id)['title'], '旧来源书名');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
