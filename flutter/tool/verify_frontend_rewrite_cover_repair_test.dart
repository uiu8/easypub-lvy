import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';

class Picker extends Fake implements BookFilePicker {}

class Desktop extends Fake implements ConversionDesktop {
  @override
  Future<String?> bundledConverter() async => null;
}

void main() {
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
  });
  for (final corrupt in [false, true]) {
    testWidgets(
      '${corrupt ? 'corrupt' : 'missing'} cover repair returns to fresh preflight',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 960);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
        final root = Directory(
          '../artifacts/frontend-rewrite/cover-repair-${DateTime.now().microsecondsSinceEpoch}',
        ).absolute;
        final backend = PrototypeState(
          settingsDirectory: '${root.path}/settings',
        );
        final library = LegacyLibraryAdapter(backend: backend);
        addTearDown(library.dispose);
        addTearDown(backend.dispose);
        final issueTitle = corrupt ? '封面图片未通过校验' : '封面文件不可访问';
        late String id, missing;
        late File source;
        const original = '第一章 来信\n河边来了信。\n第二章 夜渡\n夜色深了。\n';
        await tester.runAsync(() async {
          await root.create(recursive: true);
          source = File('${root.path}/封面修复.txt');
          await source.writeAsString(original);
          await backend.importBookOutcome(source.path);
          id = backend.currentId;
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            const Rect.fromLTWH(0, 0, 80, 120),
            Paint()..color = Colors.green,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(80, 120);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final cover = File('${root.path}/cover.png');
          await cover.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
          final info = library.openBookInformation(id);
          await info.apply(
            await info.preview({
              'language': 'zh-CN',
              'author': '作者',
              'cover_path': cover.path,
            }),
          );
          info.dispose();
          missing = cover.path;
          if (corrupt) {
            await cover.writeAsString('not a PNG');
          } else {
            await cover.delete();
          }
        });
        library.checkBook(id, true);
        Future<void> waitFor(bool Function() ready) async {
          for (var i = 0; i < 500 && !ready(); i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump();
          }
          expect(ready(), isTrue);
        }

        Future<void> settleLoaded() async {
          await tester.pump();
          await waitFor(
            () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
          );
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(
          RewriteApp(
            library: library,
            picker: Picker(),
            conversionDesktop: Desktop(),
            initialLocation: '/conversion',
          ),
        );
        await settleLoaded();
        Future<void> tap(String label) async {
          await tester.tap(find.text(label).first);
          await tester.pump();
        }

        await tester.enterText(
          find.byType(TextField).first,
          '${root.path}/output',
        );
        await tap('检查书稿');
        await waitFor(() => find.text(issueTitle).evaluate().isNotEmpty);
        expect(find.textContaining(RegExp(r'^确认(保留并)?转换$')), findsNothing);
        await tap('重新选择封面');
        await waitFor(() => find.text('使用此图片').evaluate().isNotEmpty);
        await settleLoaded();
        await tap('取消');
        await settleLoaded();
        expect(backend.production.settings(id)['cover_path'], missing);
        await tap('返回转换并重新检查');
        await waitFor(() => find.text(issueTitle).evaluate().isNotEmpty);
        await tap('生成文字封面');
        await waitFor(() => find.text('采用并返回').evaluate().isNotEmpty);
        await settleLoaded();
        await tap('采用并返回');
        await waitFor(() => find.text('保存书籍信息').evaluate().isNotEmpty);
        expect(
          backend.production.settings(id)['cover_path'],
          missing,
          reason: 'adoption remains an unsaved form',
        );
        await settleLoaded();
        await tester.tap(find.byTooltip('页面导航'));
        await tester.pumpAndSettle();
        await tap('转换设置');
        await tester.pumpAndSettle();
        expect(find.text('保留未保存的书籍信息？'), findsOneWidget);
        await tap('继续编辑');
        await tester.pumpAndSettle();
        expect(backend.production.settings(id)['cover_path'], missing);
        await tap('保存书籍信息');
        await waitFor(() => find.text('确认保存').evaluate().isNotEmpty);
        await tap('确认保存');
        await waitFor(
          () => backend.production.settings(id)['cover_path'] != missing,
        );
        await waitFor(() => find.byType(Dialog).evaluate().isEmpty);
        await tap('返回转换并重新检查');
        await waitFor(
          () => find
              .textContaining(RegExp(r'^确认(保留并)?转换$'))
              .evaluate()
              .isNotEmpty,
        );
        expect(find.text(issueTitle), findsNothing);
        expect(find.text('转换前自动检查'), findsOneWidget);
        await tester.runAsync(() async {
          expect(await source.readAsString(), original);
          expect(
            await File(backend.production.settings(id)['cover_path'] as String)
                .exists(),
            isTrue,
          );
          final output = Directory('${root.path}/output');
          if (await output.exists()) {
            expect(
              await output.list().isEmpty,
              isTrue,
              reason: 'fresh preview never commits',
            );
          }
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
