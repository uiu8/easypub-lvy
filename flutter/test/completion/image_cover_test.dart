import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/metadata/cover_image_dialog.dart';
import 'package:easypub_desktop/desk/metadata/cover_adjustment_page.dart';
import 'package:easypub_desktop/desk/metadata/cover_preview.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';

import 'library_removal_test.dart' as setup;

void main() {
  testWidgets(
    'image dialog fit pixels refresh after replacement; reset crop and actual MOBI cover remain coherent',
    (t) async {
      t.view.physicalSize = const Size(1100, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
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
      });
      final (state, library, root) = (await t.runAsync(setup.fixture))!;
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final id = library.books.value.first.id;
      final info = library.openBookInformation(id);
      addTearDown(info.dispose);
      final path = '$root/selected.png';
      Future<void> image(Color color) async {
        final recorder = ui.PictureRecorder();
        Canvas(
          recorder,
        ).drawRect(const Rect.fromLTWH(0, 0, 90, 30), Paint()..color = color);
        final picture = recorder.endRecording();
        final image = await picture.toImage(90, 30);
        picture.dispose();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
      }

      await t.runAsync(() => image(const Color(0xffff0000)));
      final capture = GlobalKey();
      CoverImageChoice? choice;
      var scale = 1.0;
      Future<void> screenshot(String name) async {
        await t.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File('$root/$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      }

      Widget app(Widget child) => RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: deskTheme(),
          debugShowCheckedModeBanner: false,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: child),
        ),
      );
      await t.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                choice = await showDialog<CoverImageChoice>(
                  context: context,
                  builder: (_) => CoverImageDialog(
                    session: info,
                    pickImage: () async => path,
                    initialFit: 'contain',
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 300; i++) {
          await t.pump(const Duration(milliseconds: 25));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty) {
            await t.pump(const Duration(milliseconds: 250));
            return;
          }
        }
        fail('image operation did not finish');
      }

      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      await t.tap(find.text('浏览图片'));
      await settle();
      final preview = find.byKey(const ValueKey('selected-cover-preview'));
      Future<List<int>> topPixel() async {
        final point = t.getTopLeft(preview) + const Offset(30, 10);
        return (await t.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final raw = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final offset =
              (point.dy.floor() * image.width + point.dx.floor()) * 4;
          final value = [for (var i = 0; i < 3; i++) raw!.getUint8(offset + i)];
          image.dispose();
          return value;
        }))!;
      }

      // 留白取画布色 Desk.light.canvas（V1 纸与墨：#F6F4EF）。
      expect(await topPixel(), [246, 244, 239]);
      Future<void> fit(String text) async {
        await t.tap(find.byType(DeskChoice<String>));
        await t.pumpAndSettle();
        await t.tap(find.text(text).last);
        await t.pumpAndSettle();
      }

      await fit('填满封面 · 保持比例');
      expect(await topPixel(), [255, 0, 0]);
      expect(t.widget<CoverPreview>(preview).fit, BoxFit.cover);
      await fit('拉伸填满');
      expect(t.widget<CoverPreview>(preview).fit, BoxFit.fill);
      await t.runAsync(() => image(const Color(0xffffff00)));
      await t.tap(find.text('使用此图片'));
      await settle();
      expect(choice, isNull);
      expect(find.text('图片文件已改变，请查看新预览后再次确认。'), findsOneWidget);
      expect(await topPixel(), [255, 255, 0]);
      await screenshot('image-dialog');
      await t.tap(find.text('使用此图片'));
      await settle();
      expect(choice, isNotNull);
      expect(choice!.fit, 'fill');
      CoverAdjustment? adjustment;
      final adjustmentPage = CoverAdjustmentPage(
        session: info,
        path: path,
        initialCrop: const {'x': .1, 'y': .1, 'width': .8, 'height': .8},
        initialFit: choice!.fit,
        onReturn: (value) => adjustment = value,
      );
      await t.pumpWidget(app(adjustmentPage));
      await settle();
      await t.tap(find.text('原图比例'));
      await t.pumpAndSettle();
      expect(
        t
            .widget<RangeSlider>(find.byKey(const ValueKey('cover-horizontal')))
            .values
            .start,
        .1,
      );
      await t.tap(find.text('重置裁切'));
      await t.pumpAndSettle();
      expect(
        t
            .widget<RangeSlider>(find.byKey(const ValueKey('cover-horizontal')))
            .values,
        const RangeValues(0, 1),
      );
      await t.tap(find.text('拉伸填满'));
      await t.pumpAndSettle();
      t
          .widget<RangeSlider>(find.byKey(const ValueKey('cover-horizontal')))
          .onChanged!(const RangeValues(.5, 1));
      await t.pumpAndSettle();
      await screenshot('image-adjustment');
      scale = 1.3;
      t.view.physicalSize = const Size(900, 720);
      await t.pumpWidget(app(adjustmentPage));
      await settle();
      expect(t.takeException(), isNull);
      expect(find.text('采用并返回').hitTestable(), findsOneWidget);
      await screenshot('image-adjustment-narrow');
      await t.tap(find.text('采用并返回'));
      await settle();
      expect(adjustment!.fit, 'fill');
      expect(adjustment!.crop!['width'], .5);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        await info.apply(
          await info.preview({
            'cover_path': path,
            'cover_fit': adjustment!.fit,
            'cover_crop': adjustment!.crop,
          }),
        );
        final project = '$root/image.easypub.json';
        expect((await library.saveProject(project)).succeeded, true);
        expect((await library.openProject(project)).succeeded, true);
        expect(
          library.books.value.singleWhere((b) => b.id == id).coverCrop,
          adjustment!.crop,
        );
        final converter = LegacyConversionSession(state);
        try {
          final plan = await converter.preview(
            ConversionRequest(
              books: [id],
              directory: '$root/image-output',
              format: 'MOBI',
              engine: Platform.environment['EASYPUB_TEST_KINDLING']!,
              runChecks: false,
            ),
          );
          final output = (await converter.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(output.complete, true, reason: output.detail);
          final extracted = await Process.run(
            Platform.environment['EASYPUB_TEST_PYTHON']!,
            [
              '-X',
              'utf8',
              '-c',
              r'''
import struct,sys,json
b=open(sys.argv[1],'rb').read()
assert b[60:68]==b'BOOKMOBI'
u16=lambda p:struct.unpack_from('>H',b,p)[0]
u32=lambda p:struct.unpack_from('>I',b,p)[0]
n=u16(76); offsets=[u32(78+8*i) for i in range(n)]+[len(b)]
r=offsets[0]; m=r+16
assert b[m:m+4]==b'MOBI'
first=u32(m+92); ex=m+u32(m+4)
assert b[ex:ex+4]==b'EXTH'
pos=ex+12; cover=None
for _ in range(u32(ex+8)):
 kind,size=u32(pos),u32(pos+4)
 assert size>=8
 if kind==201: cover=u32(pos+8)
 pos+=size
assert cover is not None
index=first+cover; assert 0<=index<n
open(sys.argv[2],'wb').write(b[offsets[index]:offsets[index+1]])
print(json.dumps({'record':index,'firstImage':first,'coverOffset':cover,'bytes':offsets[index+1]-offsets[index]}))
''',
              output.path,
              '$root/mobi-cover.png',
            ],
          );
          expect(extracted.exitCode, 0, reason: extracted.stderr.toString());
          final codec = await ui.instantiateImageCodec(
            await File('$root/mobi-cover.png').readAsBytes(),
          );
          final image = (await codec.getNextFrame()).image;
          codec.dispose();
          expect(image.width, 45);
          expect(image.height, 30);
          final pixels = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          expect(
            [pixels!.getUint8(0), pixels.getUint8(1), pixels.getUint8(2)],
            [255, 255, 0],
          );
          File('$root/image-cover-evidence.json').writeAsStringSync(
            jsonEncode({
              'mobi': output.path,
              'cover': '$root/mobi-cover.png',
              'record': jsonDecode(extracted.stdout.toString()),
              'fit': adjustment!.fit,
              'crop': adjustment!.crop,
              'pixel': [255, 255, 0],
            }),
          );
        } finally {
          converter.dispose();
        }
      });
      expect(t.takeException(), isNull);
    },
  );
}
