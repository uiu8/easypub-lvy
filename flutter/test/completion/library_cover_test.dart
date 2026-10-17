import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/desk/library/book_summary_panel.dart';
import 'package:easypub_desktop/desk/metadata/cover_preview.dart';

import 'library_removal_test.dart' as setup;

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  testWidgets(
    'saved crop fit reaches library pixels reopened project and actual EPUB; same path replacement refreshes',
    (t) async {
      final data = await t.runAsync(setup.fixture);
      final (state, library, root) = data!;
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final id = library.books.value.first.id;
      final path = '$root/colors.png';
      Future<void> writeImage(Color left, Color right) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 60, 160),
          Paint()..color = left,
        );
        canvas.drawRect(
          const Rect.fromLTWH(60, 0, 60, 160),
          Paint()..color = right,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(120, 160);
        picture.dispose();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
      }

      await t.runAsync(
        () => writeImage(const Color(0xffff0000), const Color(0xff0000ff)),
      );
      File('$root/source-cover.png')
          .writeAsBytesSync(File(path).readAsBytesSync());
      final crop = {'x': 0.5, 'y': 0.0, 'width': 0.5, 'height': 1.0};
      final info = library.openBookInformation(id);
      await t.runAsync(() async {
        await info.apply(
          await info.preview({
            'cover_path': path,
            'cover_fit': 'cover',
            'cover_crop': crop,
          }),
        );
      });
      info.dispose();
      final book = library.books.value.singleWhere((b) => b.id == id);
      expect(book.coverFit, 'cover');
      expect(book.coverCrop, crop);
      final capture = GlobalKey();
      Widget app(Widget child) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(key: capture, child: child),
          ),
        ),
      );
      Future<void> ready() async {
        for (var i = 0; i < 500; i++) {
          await t.pump(const Duration(milliseconds: 20));
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        fail('cover did not decode');
      }

      await t.pumpWidget(app(LibraryCover(book, width: 120)));
      await ready();
      final preview = t.widget<CoverPreview>(find.byType(CoverPreview));
      expect(preview.crop, crop);
      expect(preview.fit, BoxFit.cover);
      Future<List<int>> centerPixel() async {
        final result = await t.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final offset =
              ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
          final color = [
            for (var i = 0; i < 4; i++) bytes!.getUint8(offset + i),
          ];
          image.dispose();
          return color;
        });
        return result!;
      }

      expect(await centerPixel(), [0, 0, 255, 255]);
      await t.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('$root/preview-cover.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
      await t.runAsync(() async {
        expect(
          (await library.saveProject('$root/cover.easypub.json')).succeeded,
          true,
        );
        expect(
          (await library.openProject('$root/cover.easypub.json')).succeeded,
          true,
        );
        final reopened = library.books.value.singleWhere((b) => b.id == id);
        expect(reopened.coverCrop, crop);
        expect(reopened.coverFit, 'cover');
        final converter = LegacyConversionSession(state);
        try {
          final plan = await converter.preview(
            ConversionRequest(
              books: [id],
              directory: '$root/output',
              format: 'EPUB',
              runChecks: false,
            ),
          );
          final output = (await converter.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(output.complete, true);
          final extracted = await Process.run(
            Platform.environment['EASYPUB_TEST_PYTHON']!,
            [
              '-X',
              'utf8',
              '-c',
              'import zipfile,sys,posixpath,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); c=E.fromstring(z.read("META-INF/container.xml")); p=c.find(".//{*}rootfile").attrib["full-path"]; opf=E.fromstring(z.read(p)); cover=next(n for n in opf.findall(".//{*}item") if "cover-image" in n.attrib.get("properties", "").split()); open(sys.argv[2],"wb").write(z.read(posixpath.normpath(posixpath.join(posixpath.dirname(p),cover.attrib["href"]))))',
              output.path,
              '$root/exported-cover.png',
            ],
          );
          expect(extracted.exitCode, 0, reason: extracted.stderr.toString());
          final codec = await ui.instantiateImageCodec(
            await File('$root/exported-cover.png').readAsBytes(),
          );
          final frame = await codec.getNextFrame();
          codec.dispose();
          expect(frame.image.width, 60);
          expect(frame.image.height, 160);
          final bytes = (await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          expect(
            [bytes.getUint8(0), bytes.getUint8(1), bytes.getUint8(2)],
            [0, 0, 255],
          );
          frame.image.dispose();
          File('$root/cover-output-evidence.json').writeAsStringSync(
            jsonEncode({
              'epub': output.path,
              'cover': '$root/exported-cover.png',
              'crop': crop,
              'fit': 'cover',
              'width': 60,
              'height': 160,
              'pixel': [0, 0, 255],
            }),
          );
        } finally {
          converter.dispose();
        }
      });
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(app(CoverPreview(path: path, decodeWidth: 120)));
      await ready();
      await t.runAsync(
        () => writeImage(const Color(0xffffff00), const Color(0xffffff00)),
      );
      await t.pumpWidget(
        app(
          CoverPreview(path: path, decodeWidth: 120, revision: 'replacement'),
        ),
      );
      await ready();
      expect(await centerPixel(), [255, 255, 0, 255]);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
