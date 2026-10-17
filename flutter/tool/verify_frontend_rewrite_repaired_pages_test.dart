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
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';

class Picker extends Fake implements BookFilePicker {}

void main() {
  testWidgets(
    'repaired library overview chapters and cleanup show real book state',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      late LegacyLibraryAdapter library;
      late PrototypeState backend;
      final root = Directory('../artifacts/repair-review-20261003');
      await tester.runAsync(() async {
        for (final entry in {
          'Microsoft YaHei': r'C:\Windows\Fonts\msyh.ttc',
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
            File('../target/release/easypub_bridge.dll').absolute.path,
          ),
        );
        await root.create(recursive: true);
        final run = await root.createTemp('run-');
        backend = PrototypeState(
          settingsDirectory: '${run.absolute.path}/settings',
        );
        library = LegacyLibraryAdapter(backend: backend);
        final file = File('${run.path}/长河照影.txt');
        await file.writeAsString(
          List.generate(
            65,
            (i) => '第${i + 1}章 河边来信\n天色渐晚，河边传来脚步声。  \n\n\n他停下来，仔细读着手里的来信。\n',
          ).join(),
        );
        expect(
          (await library.importFiles([file.absolute.path])).single.succeeded,
          true,
        );
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: RewriteApp(library: library, picker: Picker()),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 250; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (i > 12 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            break;
          }
        }
        expect(tester.takeException(), isNull);
      }

      Future<void> shot(String name) async {
        await settle();
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${root.path}/$name.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await shot('library');
      expect(find.text('编辑章节'), findsOneWidget);
      await tester.tap(find.text('概览').first);
      await shot('overview');
      expect(find.text('制作进度'), findsOneWidget);
      expect(find.text('检查摘要'), findsOneWidget);
      await tester.tap(find.text('章节').first);
      await shot('chapters');
      expect(find.text('有效结构预览'), findsNothing);
      await tester.enterText(find.byType(TextField).first, '第61章');
      await settle();
      expect(find.text('第61章 河边来信'), findsOneWidget);
      await tester.tap(find.text('第61章 河边来信'));
      await settle();
      expect(find.textContaining('河边传来脚步声'), findsWidgets);
      await tester.tap(find.text('文本清理').first);
      await shot('cleanup');
      expect(find.text('清理所选项'), findsOneWidget);
      expect(find.textContaining('检测完成'), findsWidgets);
      tester.view.physicalSize = const Size(1080, 720);
      await shot('cleanup-small');
      await tester.runAsync(() async {
        expect(
          await library.savePatch({'ui_scale': 1.3, 'reduced_motion': true}),
          true,
        );
      });
      await shot('cleanup-small-130');
      await tester.tap(find.text('概览').first);
      await shot('overview-small-130');
      await tester.tap(find.text('章节').first);
      await shot('chapters-small-130');
      await tester.tap(find.text('设置').first);
      await shot('settings-small-130');
      tester.view.physicalSize=const Size(1440,960);
      await tester.runAsync(() async { await library.savePatch({'ui_scale':1.0}); });
      await tester.tap(find.text('检查与修复').first);
      await shot('checks');
      await tester.tap(find.text('查看全部章节问题'));
      await settle();
      expect(find.text('问题与定位'),findsOneWidget);
      await tester.tap(find.text('检查与修复').first);
      await settle();
      await tester.tap(find.text('查看').at(1));
      await tester.pump();
      await tester.tap(find.text('编辑书籍信息'));
      await settle();
      expect(find.text('保存书籍信息'),findsWidgets);

      await tester.pumpWidget(const SizedBox());
      library.dispose();
      backend.dispose();
    },
  );
}
