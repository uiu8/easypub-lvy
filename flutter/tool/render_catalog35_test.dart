import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/catalog/source_dialog.dart';

import '../test/completion/catalog_search_test.dart' show SearchCatalog;

void main() {
  testWidgets('render long catalog input at desktop and narrow enlarged text', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.runAsync(() async {
      await (FontLoader('Microsoft YaHei')..addFont(
            File('C:/Windows/Fonts/msyh.ttc')
                .readAsBytes()
                .then((b) => b.buffer.asByteData()),
          ))
          .load();
      await (FontLoader('MaterialIcons')..addFont(
            File(
              'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    });
    for (final spec in [
      (1400.0, 1200.0, 1.0, 'catalog-paste'),
      (650.0, 1000.0, 1.3, 'catalog-paste-narrow'),
    ]) {
      t.view.physicalSize = Size(spec.$1, spec.$2);
      final key = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(spec.$1, spec.$2),
                textScaler: TextScaler.linear(spec.$3),
              ),
              child: Scaffold(
                body: CatalogSourceDialog(
                  key: ValueKey(spec.$4),
                  session: SearchCatalog(),
                  pickFile: () async => null,
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('粘贴目录'));
      await t.pump();
      await t.enterText(
        find.byType(TextField).first,
        List.generate(
          30000,
          (i) => '第${i + 1}章 长河照影 · 第${i + 1}段旅程',
        ).join('\n'),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        final file = File(
          '../design/review-20261004-v2.8/screens/${spec.$4}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        image.dispose();
      });
    }
  });
}
