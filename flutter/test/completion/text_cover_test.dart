import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/desk/metadata/text_cover.dart';
import 'package:easypub_desktop/desk/metadata/cover_editor_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

import 'library_removal_test.dart' as setup;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'long cover title includes its last character with no ellipsis or overlap',
    () {
      final text = '长河照影：${'穿越山海寻找故人'.padRight(80, '归')}终';
      final layout = TextCoverPainter.fitText(
        text,
        bounds: const Size(888, 600),
        maximum: 170,
        minimum: 36,
        bold: true,
      )!;
      expect(layout.text!.toPlainText(), text);
      expect(layout.ellipsis, isNull);
      expect(layout.maxLines, isNull);
      expect(layout.height, lessThanOrEqualTo(600));
      final last = layout.getBoxesForSelection(
        TextSelection(baseOffset: text.length - 1, extentOffset: text.length),
      );
      expect(last, isNotEmpty);
      expect(last.single.bottom, lessThanOrEqualTo(600));
      expect(last.single.right, lessThanOrEqualTo(888));
      layout.dispose();
    },
  );
  test('unreadable manual lines and empty title fail visibly before image generation', () async {
    final painter = TextCoverPainter(
      List.filled(30, '长').join('\n'),
      '',
      '',
      Colors.green,
    );
    expect(painter.validationMessage, contains('封面标题过长'));
    await expectLater(painter.render(), throwsFormatException);
    expect(
      const TextCoverPainter(' ', '', '', Colors.green).validationMessage,
      contains('请填写'),
    );
    expect(
      const TextCoverPainter('书名', '作者', '系列', Colors.green).validationMessage,
      isNull,
    );
  });
  testWidgets(
    'text cover mode drafts survive switches and generated PNG survives save reopen EPUB',
    (t) async {
      t.view.physicalSize = const Size(1100, 760);
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
      final bookTitle = library.books.value.first.title;
      final info = library.openBookInformation(id);
      addTearDown(info.dispose);
      CoverEditorResult? result;
      final capture = GlobalKey();
      Widget app(double scale) => MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(
              key: capture,
              child: CoverEditorPage(
                session: info,
                title: bookTitle,
                author: '林间客',
                series: '长河纪事',
                path: null,
                fit: 'contain',
                crop: null,
                design: null,
                startWithText: true,
                pickImage: () async => null,
                onReturn: (value) => result = value,
              ),
            ),
          ),
        ),
      );
      await t.pumpWidget(app(1));
      const title = '长河照影：穿越群山与大海，在漫长岁月里重新寻找故乡、旧友和未曾说完的故事';
      await t.enterText(find.byKey(const ValueKey('cover-封面标题')), title);
      await t.pump();
      expect(find.text('裁切填充'), findsNothing);
      await t.tap(find.byKey(const ValueKey('cover-mode-false')));
      await t.pump();
      expect(find.text('裁切填充'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('cover-mode-true')));
      await t.pump();
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('cover-封面标题')))
            .controller!
            .text,
        title,
      );
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

      await screenshot('text-cover-wide');
      t.view.physicalSize = const Size(900, 720);
      await t.pumpWidget(app(1.3));
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.text('采用并返回').hitTestable(), findsOneWidget);
      await screenshot('text-cover-narrow');
      await t.tap(find.text('采用并返回'));
      for (var i = 0; i < 1000 && result == null; i++) {
        await t.pump(const Duration(milliseconds: 20));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(result, isNotNull);
      final adopted = result!;
      expect(adopted.design!['title'], title);

      expect(adopted.crop, isNull);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        await info.apply(
          await info.preview({
            'cover_path': adopted.path,
            'cover_design': adopted.design,
            'cover_fit': adopted.fit,
          }),
        );
        expect(
          library.books.value.singleWhere((b) => b.id == id).title,
          bookTitle,
        );
        final project = '$root/text-cover.easypub.json';
        expect((await library.saveProject(project)).succeeded, true);
        expect((await library.openProject(project)).succeeded, true);
        expect(
          library.books.value
              .singleWhere((b) => b.id == id)
              .coverDesign!['title'],
          title,
        );
        final converter = LegacyConversionSession(state);
        try {
          final plan = await converter.preview(
            ConversionRequest(
              books: [id],
              directory: '$root/text-output',
              format: 'EPUB',
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
              'import zipfile,sys,posixpath,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); c=E.fromstring(z.read("META-INF/container.xml")); p=c.find(".//{*}rootfile").attrib["full-path"]; opf=E.fromstring(z.read(p)); cover=next(n for n in opf.findall(".//{*}item") if "cover-image" in n.attrib.get("properties", "").split()); open(sys.argv[2],"wb").write(z.read(posixpath.normpath(posixpath.join(posixpath.dirname(p),cover.attrib["href"]))))',
              output.path,
              '$root/text-exported.png',
            ],
          );
          expect(extracted.exitCode, 0, reason: extracted.stderr.toString());
          Future<List<int>> pixels(String path) async {
            final codec = await ui.instantiateImageCodec(
              await File(path).readAsBytes(),
            );
            final image = (await codec.getNextFrame()).image;
            codec.dispose();
            expect(image.width, 1200);
            expect(image.height, 1600);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            image.dispose();
            return bytes!.buffer.asUint8List();
          }

          expect(
            await pixels('$root/text-exported.png'),
            await pixels(adopted.path),
          );
          File('$root/text-cover-evidence.json').writeAsStringSync(
            jsonEncode({
              'title': title,
              'originalTitle': bookTitle,
              'generated': adopted.path,
              'exported': '$root/text-exported.png',
              'epub': output.path,
              'pixelsEqual': true,
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
