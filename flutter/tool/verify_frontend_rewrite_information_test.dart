import 'package:easypub_desktop/desk/metadata/text_cover.dart';
import 'package:easypub_desktop/desk/metadata/cover_preview.dart';

import 'dart:io';

import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' show ApiError;
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/metadata/book_information_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'legacy_state_helpers.dart';

class _Picker implements BookFilePicker {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'information automatic application, cover adoption, stale guard and project recovery',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          null,
        ),
      );
      final backend = PrototypeState(
        settingsDirectory: Directory(
          '../artifacts/frontend-rewrite/information-probe/settings',
        ).absolute.path,
      );
      addTearDown(backend.dispose);
      final dir = Directory('../artifacts/frontend-rewrite/information-probe');
      final source = File('${dir.path}/信息样书.txt');
      final cover = File('${dir.path}/cover.png');
      late Uint8List coverBytes;
      const original = '第一章 夜渡\n夜色落在河面上。\n第二章 来信\n远方来了信。\n';
      await tester.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            File(
              Platform.environment['EASYPUB_TEST_DLL'] ??
                  '../target/release/easypub_bridge.dll',
            ).absolute.path,
          ),
        );
        await dir.create(recursive: true);
        await source.writeAsString(original);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 120, 160),
          Paint()..color = Desk.light.accent,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(120, 160);
        coverBytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        await cover.writeAsBytes(coverBytes);
        image.dispose();
        picture.dispose();
        for (final entry in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(entry.key)..addFont(
                File(entry.value)
                    .readAsBytes()
                    .then((v) => v.buffer.asByteData()),
              ))
              .load();
        }
        await backend.importBookOutcome(source.absolute.path);
      });
      final library = LegacyLibraryAdapter(backend: backend);
      addTearDown(library.dispose);
      final id = backend.currentId;
      final navigation = InformationNavigationGuard();
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: BookInformationPage(
                  library: library,
                  bookId: id,
                  navigation: navigation,
                  pickImage: () async => cover.absolute.path,
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> settleFrames() async {
        await tester.pump();
        for (
          var i = 0;
          i < 400 &&
              (find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
                  find.byType(LinearProgressIndicator).evaluate().isNotEmpty);
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
      }

      Future<void> settleWork() async {
        await tester.pump(const Duration(milliseconds: 500));
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          if (library.readDraft('metadata:$id') == null &&
              !backend.production.busy) {
            break;
          }
        }
        await settleFrames();
      }

      final title = find.byKey(const ValueKey('information-title'));
      final originalTitleField = tester.widget<TextField>(title);
      await tester.enterText(title, '长河照影');
      await tester.enterText(
        find.byKey(const ValueKey('information-author')),
        '林间客',
      );
      await tester.pump();
      expect(
        tester.widget<TextField>(title).controller,
        same(originalTitleField.controller),
      );
      expect(tester.widget<TextField>(title).controller!.text, '长河照影');
      expect(find.text('长河照影 · 林间客'), findsOneWidget);
      await tester.tap(find.text('浏览图片…'));
      await settleWork();
      await settleFrames();
      expect(find.text('选择封面图片'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await settleFrames();
      expect(backend.production.settings(id)['cover_path'], isNull);
      await tester.tap(find.text('浏览图片…'));
      await settleWork();
      await settleFrames();
      await tester.tap(find.text('浏览图片'));
      await tester.pump();
      for (var i = 0; i < 100 && find.text('图片检查通过').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await settleFrames();
      expect(find.text('图片检查通过'), findsOneWidget);
      for (
        var i = 0;
        i < 100 &&
            !tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .any((v) => v.painter is CoverRegionPainter);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(
        tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .any((v) => v.painter is CoverRegionPainter),
        true,
      );

      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/cover-image.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(backend.production.settings(id)['cover_path'], isNull);
      await tester.tap(find.text('使用此图片'));
      await tester.pump();
      for (
        var i = 0;
        i < 100 && find.text('选择封面图片').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await settleFrames();
      for (final entry in {
        'series': '长河纪事',
        'series_index': '2.2.1',
        'subjects': '旅行、群像',
      }.entries) {
        final field = find.byKey(ValueKey('information-${entry.key}'));
        await tester.ensureVisible(field);
        await tester.enterText(field, entry.value);
      }
      await tester.tap(find.text('裁切与调整'));
      await settleWork();
      await tester.pump();
      for (
        var i = 0;
        i < 100 && find.byType(CoverPreview).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await settleFrames();
      final slider = tester.widget<RangeSlider>(
        find.byKey(const ValueKey('cover-horizontal')),
      );
      slider.onChanged!(const RangeValues(.2, .8));
      await tester.pump();
      expect(backend.production.settings(id)['cover_crop'], isNull);
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/cover-adjustment.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('采用并返回'));
      await tester.pump();
      for (
        var i = 0;
        i < 100 && find.text('采用并返回').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await settleFrames();
      await settleWork();
      expect(find.text('确认书籍信息变更'), findsNothing);
      expect((backend.production.settings(id)['cover_crop'] as Map)['x'], .2);
      expect(backend.production.settings(id)['title'], '长河照影');
      expect(backend.production.settings(id)['cover_path'], cover.absolute.path);
      await tester.ensureVisible(title);
      await tester.enterText(title, '切页自动保存书名');
      bool? canLeave;
      navigation.canLeave().then((value) => canLeave = value);
      await settleWork();
      expect(find.text('保留未保存的书籍信息？'), findsNothing);
      expect(canLeave, true);
      expect(backend.production.settings(id)['title'], '切页自动保存书名');
      await tester.enterText(title, '长河照影');
      await settleWork();
      expect(tester.widget<TextField>(title).controller!.text, '长河照影');
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/metadata.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        final session = library.openBookInformation(id);
        final invalid = File('${dir.path}/invalid.png');
        await invalid.writeAsString('not an image');
        await expectLater(
          session.inspectImage(invalid.absolute.path),
          throwsA(anything),
        );
        final inspected = await session.inspectImage(cover.absolute.path);
        expect(inspected.width, 120);
        expect(inspected.height, 160);
        expect(inspected.bytes, coverBytes.length);
        final saved = session.saved;
        final pending = await session.preview({...saved, 'publisher': '河畔出版社'});
        backend.change(() => backend.draftFor(id).description = '另一个编辑窗口');
        await expectLater(session.apply(pending), throwsFormatException);
        expect(backend.production.settings(id)['publisher'], isNot('河畔出版社'));
        final current = session.saved;
        await session.apply(
          await session.preview({...current, 'publisher': '河畔出版社'}),
        );
        final project =
            '${dir.absolute.path}/project-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
        expect((await library.saveProject(project)).succeeded, true);
        backend.change(() => backend.draftFor(id).title = '临时');
        expect((await library.openProject(project)).succeeded, true);
        expect(backend.production.settings(id)['title'], '长河照影');
        expect(backend.production.settings(id)['publisher'], '河畔出版社');
        expect((backend.production.settings(id)['cover_crop'] as Map)['x'], .2);
        expect(
          (backend.production.settings(id)['cover_crop'] as Map)['width'],
          closeTo(.6, .00001),
        );
        expect(backend.production.settings(id)['series'], '长河纪事');
        expect(backend.production.settings(id)['series_index'], '2.2.1');
        expect(backend.production.settings(id)['subjects'], '旅行、群像');
        expect(
          backend.production.settings(id)['cover_path'],
          cover.absolute.path,
        );
        expect(await cover.readAsBytes(), coverBytes);
        expect(await source.readAsString(), original);
        session.dispose();
      });
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: RewriteApp(library: library, picker: _Picker()),
        ),
      );
      await settleFrames();
      await tester.tap(find.text('书籍信息'));
      await settleFrames();
      expect(find.byKey(const ValueKey('information-title')), findsOneWidget);
      expect(find.text('元信息'), findsOneWidget);
      for (
        var i = 0;
        i < 100 &&
            !tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .any((v) => v.painter is CoverRegionPainter);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(
        tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .any((v) => v.painter is CoverRegionPainter),
        true,
      );
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/metadata-workspace.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      final priorCover = backend.production.settings(id)['cover_path'];
      await tester.tap(find.text('生成文字封面'));
      await settleFrames();
      expect(find.text('封面调整'), findsNWidgets(2));
      final previewSize = tester.getSize(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is TextCoverPainter,
        ),
      );
      expect(previewSize.aspectRatio, closeTo(3 / 4, .001));
      final coverTitleField = find.byKey(const ValueKey('cover-封面标题'));
      final originalCoverField = tester.widget<TextField>(coverTitleField);
      await tester.enterText(coverTitleField, '独立封面标题');
      await tester.enterText(find.byKey(const ValueKey('cover-作者署名')), '林间客 著');
      await tester.pump();
      expect(
        tester.widget<TextField>(coverTitleField).controller,
        same(originalCoverField.controller),
      );
      final coverPaint = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is TextCoverPainter,
        ),
      );
      expect((coverPaint.painter! as TextCoverPainter).title, '独立封面标题');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cover-mode-false')));
      await settleFrames();
      final modeSlider = tester.widget<RangeSlider>(
        find.byKey(const ValueKey('cover-horizontal')),
      );
      modeSlider.onChanged!(const RangeValues(.1, .9));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cover-mode-true')));
      await settleFrames();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cover-封面标题')))
            .controller!
            .text,
        '独立封面标题',
      );
      await tester.tap(find.byKey(const ValueKey('cover-mode-false')));
      await settleFrames();
      expect(
        tester
            .widget<RangeSlider>(find.byKey(const ValueKey('cover-horizontal')))
            .values,
        const RangeValues(.1, .9),
      );
      expect(backend.production.settings(id)['cover_path'], priorCover);
      await tester.drag(
        find.byKey(const ValueKey('cover-pan-surface')),
        const Offset(35, 0),
      );
      await settleFrames();
      final draggedRange = tester
          .widget<RangeSlider>(find.byKey(const ValueKey('cover-horizontal')))
          .values;
      expect(draggedRange.start, lessThan(.1));
      expect(backend.production.settings(id)['cover_path'], priorCover);
      await tester.tap(find.text('原图比例'));
      await settleFrames();
      expect(
        tester.widget<CoverPreview>(find.byType(CoverPreview)).crop,
        isNull,
      );
      expect(
        tester
            .widget<RangeSlider>(find.byKey(const ValueKey('cover-horizontal')))
            .values,
        draggedRange,
      );
      await tester.tap(find.text('裁切填充'));
      await settleFrames();
      expect(
        tester.widget<CoverPreview>(find.byType(CoverPreview)).crop,
        isNotNull,
      );
      expect(
        tester.widget<CoverPreview>(find.byType(CoverPreview)).fit,
        BoxFit.cover,
      );
      await tester.tap(find.text('重置裁切'));
      await settleFrames();
      expect(
        tester
            .widget<RangeSlider>(find.byKey(const ValueKey('cover-horizontal')))
            .values,
        const RangeValues(0, 1),
      );
      await tester.tap(find.byKey(const ValueKey('cover-mode-true')));
      await settleFrames();
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/text-cover.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('采用并返回'));
      await tester.pump();
      for (
        var i = 0;
        i < 200 && find.text('采用并返回').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await settleFrames();
      await settleWork();
      final generated = backend.production.settings(id)['cover_path'] as String;
      expect(generated, isNot(priorCover));
      expect(backend.production.settings(id)['title'], '长河照影');
      await tester.runAsync(() async {
        final session = library.openBookInformation(id);
        final evidence = await session.inspectImage(generated);
        expect(evidence.width, 1200);
        expect(evidence.height, 1600);
        expect(evidence.format, 'png');
        final rendered = await const TextCoverPainter(
          '独立封面标题',
          '林间客 著',
          '长河纪事',
          Desk.light.accent,
        ).render();
        final expected = await rendered.toByteData(
          format: ui.ImageByteFormat.png,
        );
        expect(
          await File(generated).readAsBytes(),
          expected!.buffer.asUint8List(),
        );
        rendered.dispose();

        final project =
            '${dir.absolute.path}/generated-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
        expect((await library.saveProject(project)).succeeded, true);
        expect((await library.openProject(project)).succeeded, true);
        expect(backend.production.settings(id)['cover_path'], generated);
        expect(
          (backend.production.settings(id)['cover_design'] as Map)['title'],
          '独立封面标题',
        );
        expect(
          (backend.production.settings(id)['cover_design']
              as Map)['image_sha256'],
          evidence.sha256,
        );
        expect(await cover.readAsBytes(), coverBytes);
        expect(await source.readAsString(), original);
        session.dispose();
      });
      // Opening a project intentionally rebuilds the workspace at the library.
      await settleFrames();
      await tester.tap(find.text('书籍信息').first);
      await settleFrames();
      await tester.tap(find.text('生成文字封面'));
      await settleFrames();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cover-封面标题')))
            .controller!
            .text,
        '独立封面标题',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cover-作者署名')))
            .controller!
            .text,
        '林间客 著',
      );
      await tester.tap(find.text('取消'));
      await settleFrames();
      await tester.runAsync(() async {
        final session = library.openBookInformation(id);
        final originalGenerated = await File(generated).readAsBytes();
        try {
          await File(generated).writeAsBytes(coverBytes, flush: true);
          await expectLater(
            session.preview({'publisher': '不得采用已改变的封面'}),
            throwsA(isA<ApiError>()),
          );
          expect(backend.production.settings(id)['cover_path'], generated);
        } finally {
          await File(generated).writeAsBytes(originalGenerated, flush: true);
        }
        final plan = await session.preview({'cover_path': cover.absolute.path});
        expect(plan.after['cover_design'], isNull);
        expect(backend.production.settings(id)['cover_design'], isNotNull);
        await session.apply(plan);
        expect(backend.production.settings(id)['cover_design'], isNull);
        session.dispose();
      });
      await tester.runAsync(() async {
        final resources = library.openResources(id);
        final originalImage = await cover.readAsBytes();
        final rows = await resources.read();
        expect(rows.any((r) => r.index == -1 && r.image != null), true);
        final add = await resources.change(
          index: null,
          path: cover.absolute.path,
          sourceLine: 2,
          alt: '地图',
          caption: '测试插图',
        );
        expect(backend.production.settings(id)['illustrations'], isEmpty);
        await resources.apply(add);
        final updated = await resources.read();
        expect(updated.where((r) => r.index >= 0).single.alt, '地图');
        final removal = await resources.change(index: 0, path: null);
        final edit = await resources.change(
          index: 0,
          path: cover.absolute.path,
          sourceLine: 2,
          alt: '新地图',
          caption: '更新图注',
        );
        await expectLater(
          resources.apply(removal),
          throwsA(isA<FormatException>()),
        );
        await resources.apply(edit);
        try {
          await cover.writeAsBytes([0, 1, 2]);
          expect(
            (await resources.read()).every((r) => r.error.isNotEmpty),
            true,
          );
        } finally {
          await cover.writeAsBytes(originalImage);
        }
        await resources.read();
        final repaired = await resources.change(
          index: 0,
          path: cover.absolute.path,
          sourceLine: 2,
          alt: '已重新定位',
        );
        await resources.apply(repaired);
        final project =
            '${dir.absolute.path}/resources-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
        expect(
          await backend.saveProjectOutcome(project),
          true,
          reason: backend.projectStatus,
        );
        expect(
          await backend.openProjectOutcome(project),
          true,
          reason: backend.projectStatus,
        );
        final reopened = library.openResources(backend.currentId);
        expect(
          (await reopened.read()).where((r) => r.index == 0).single.alt,
          '已重新定位',
        );
        final location = await reopened.locate(0);
        expect(location.nodeId, isNotNull);
        expect(location.nodeOffset, 0);
        expect(location.heading, '第一章 夜渡');
        reopened.dispose();
        resources.dispose();
        expect(await cover.readAsBytes(), originalImage);
      });
      await tester.tap(find.text('图片与资源'));
      await tester.pump();
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.text('原稿第 2 行之后').evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();
      expect(find.text('书内资源'), findsOneWidget);
      expect(find.text('原稿第 2 行之后'), findsOneWidget);
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/resources.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('移除引用'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('预览变更'));
      await tester.pump();
      for (var i = 0; i < 100 && find.text('确认应用').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(backend.production.settings(id)['cover_path'], isNotNull);
      await tester.tap(find.text('确认应用'));
      await tester.pump();
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (backend.production.settings(id)['cover_path'] == null &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
      expect(backend.production.settings(id)['cover_path'], isNull);
      await tester.runAsync(
        () async => expect(await cover.readAsBytes(), coverBytes),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('定位章节'));
      await tester.pump();
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (find
            .textContaining('夜色落在河面上', findRichText: true)
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(find.text('章节编辑'), findsOneWidget);
      expect(find.textContaining('夜色落在河面上', findRichText: true), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
