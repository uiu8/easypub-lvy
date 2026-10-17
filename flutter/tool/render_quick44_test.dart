import 'package:easypub_desktop/desk/controls/controls.dart';
import 'dart:io';
import 'dart:convert';

import 'package:easypub_desktop/desk/conversion/conversion_page.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/conversion/quick_conversion_dialog.dart';

import '../test/completion/library_removal_test.dart' as setup;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

class Desktop extends Fake
    implements ConversionDesktop, OutputDirectoryDesktop {
  Desktop(this.directory);
  final String directory;
  @override
  Future<String> defaultOutputDirectory() async => directory;
  @override
  Future<String?> bundledConverter() async =>
      Platform.environment['EASYPUB_TEST_KINDLING'];
}

class QuickLibrary extends Fake implements LibraryService {
  @override
  final books = ValueNotifier<List<BookSummary>>([
    const BookSummary(
      id: 'a',
      title: '样书',
      author: '作者',
      path: 'a.txt',
      format: 'TXT',
      chapters: 1,
      status: '',
    ),
  ]);
}

class QuickSession extends Fake implements ConversionSession {
  QuickSession(this.plan);
  final ConversionPreview plan;
  ConversionRequest? received;
  @override
  Future<ConversionPreview> preview(ConversionRequest request) async {
    received = request;
    return plan;
  }

  @override
  bool isCurrent(ConversionPreview value) => identical(plan, value);
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  for (final blocked in [false, true]) {
    testWidgets(
      'quick summary keeps warnings optional and blockers mandatory: $blocked',
      (t) async {
        final session = QuickSession(
          ConversionPreview(
            [
              ConversionFinding(
                'a',
                '测试问题',
                blocked ? 'blocking' : 'warning',
                '具体问题原因',
                'chapters',
              ),
            ],
            [],
            bookTitles: {'a': '样书'},
            previewed: !blocked,
          ),
        );
        t.view.physicalSize=const Size(1440,960);t.view.devicePixelRatio=1;
        addTearDown(t.view.resetPhysicalSize);addTearDown(t.view.resetDevicePixelRatio);
        final captureKey=GlobalKey();
        await t.runAsync(() async {
          await (FontLoader('Microsoft YaHei')..addFont(File('C:/Windows/Fonts/msyh.ttc').readAsBytes().then((b)=>b.buffer.asByteData()))).load();
          await (FontLoader('MaterialIcons')..addFont(File('D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytes().then((b)=>b.buffer.asByteData()))).load();
        });
        QuickConversionChoice? choice;
        await t.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner:false,
            theme:deskTheme(),
            builder:(_,child)=>RepaintBoundary(key:captureKey,child:child!),
            home: Scaffold(
              body: Builder(
                builder: (c) => TextButton(
                  onPressed: () async {
                    choice = await showDialog<QuickConversionChoice>(
                      context: c,
                      builder: (_) => QuickConversionDialog(
                        library: QuickLibrary(),
                        desktop: Desktop('D:/out'),
                        session: session,
                        books: ['a'],
                      ),
                    );
                  },
                  child: const Text('准备'),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('准备'));
        await t.pumpAndSettle();
        expect(find.text('样书 · 测试问题'), findsOneWidget);
        await t.runAsync(() async {
          final picture=await (captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
          final file=File('../design/review-20261005-v2.15/screens/'+(blocked?'quick-blocked':'quick-warning')+'.png');
          await file.parent.create(recursive:true);
          await file.writeAsBytes((await picture.toByteData(format:ui.ImageByteFormat.png))!.buffer.asUint8List());
          picture.dispose();
        });
        expect(find.text('继续转换'), blocked ? findsNothing : findsOneWidget);
        expect(session.received!.books, ['a']);
        expect(session.received!.directory, 'D:/out');
        if (blocked) {
          await t.tap(find.text('前往处理'));
        } else {
          await t.tap(find.text('继续转换'));
        }
        await t.pumpAndSettle();
        expect(choice!.action, blocked ? 'repair' : 'start');
        expect(choice!.request, session.received);
      },
    );
  }
  testWidgets(
    'actual app quick entry outputs selected books in EPUB AZW3 MOBI with saved defaults and no duplicate queue',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      const channel = MethodChannel('window_manager');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final data = await t.runAsync(setup.fixture);
      final (state, library, root) = data!;
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      await t.runAsync(() async {
        await Directory('$root/output').create();
      });
      final desktop = Desktop('$root/output');
      final ids = library.books.value.map((b) => b.id).toSet();
      library.checkBooks(ids, true);
      await t.pumpWidget(
        RewriteApp(
          library: library,
          picker: setup.NoPicker(),
          conversionDesktop: desktop,
        ),
      );
      await t.pumpAndSettle();
      final router = GoRouter.of(t.element(find.byType(LibraryPage)));
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 4000; i++) {
          await t.pump(const Duration(milliseconds: 20));
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        fail(
          'quick operation did not settle: ' +
              state.outputs.tasks.map((o) => o.phase).join(','),
        );
      }

      for (final format in ['EPUB', 'AZW3', 'MOBI']) {
        router.go('/');
        await t.pumpAndSettle();
        await until(() => !state.globalSettingsBusy);
        bool? saved;
        Object? saveError;
        library
            .savePatch({
              'output_format': format,
              'output_directory': '',
              'generate_cover': true,
              'check_before_conversion': false,
            })
            .then(
              (v) => saved = v,
              onError: (Object e) {
                saveError = e;
              },
            );
        await until(() => saved != null || saveError != null);
        expect(saveError, isNull);
        expect(saved, true);
        await t.pumpAndSettle();
        await until(
          () =>
              t
                  .widget<TextButton>(
                    find.widgetWithText(TextButton, '转换所选 2 本'),
                  )
                  .onPressed !=
              null,
        );
        final before = state.outputs.tasks.length;
        final action = t.widget<TextButton>(
          find.widgetWithText(TextButton, '转换所选 2 本'),
        );
        action.onPressed!();
        action.onPressed!();
        t.printToConsole('quick44 preparing: $format');
        await until(
          () =>
              find.byType(QuickConversionDialog).evaluate().isEmpty &&
              state.outputs.tasks.length >= before + 2 &&
              state.outputs.tasks.skip(before).every((o) => o.terminal),
        );
        t.printToConsole('quick44 finished: $format');
        expect(state.outputs.tasks.length, before + 2);
        expect(
          state.outputs.tasks.skip(before).every((o) => o.phase == 'complete'),
          true,
          reason: state.outputs.tasks.skip(before).map((o) => o.phase).join(','),
        );
        for (final task in state.outputs.tasks.skip(before)) {
          expect(File(task.outputPath).existsSync(), true);
          expect(task.format, format);
        }
        expect(library.selection.value.selected, ids);
        router.go('/');
        await t.pumpAndSettle();
        await until(
          () =>
              t
                  .widget<TextButton>(
                    find.widgetWithText(TextButton, '转换所选 2 本'),
                  )
                  .onPressed !=
              null,
        );
      }
      final files = Directory('$root/output').listSync();
      expect(files, hasLength(6));
      expect(files.every((f) => f is File), true);
      File('$root/quick-output-evidence.json').writeAsStringSync(
        jsonEncode([
          for (final task in state.outputs.tasks)
            {
              'id': task.bookId,
              'format': task.format,
              'path': task.outputPath,
              'receipt': task.receipt,
            },
        ]),
      );
      final bad = File('$root/跳号样书.txt')
        ..writeAsStringSync('第一章 开始\n正文甲\n第三章 跳号\n正文乙\n');
      List<ImportOutcome>? imported;
      library.importFiles([bad.path]).then((v) => imported = v);
      await until(() => imported != null);
      expect(imported!.single.succeeded, true);
      final repairIds = {library.books.value.first.id, ids.first};
      library.checkBooks(ids, false);
      library.checkBooks(repairIds, true);
      bool? settingsSaved;
      library
          .savePatch({'check_before_conversion': true})
          .then((v) => settingsSaved = v);
      await until(() => settingsSaved != null);
      expect(settingsSaved, true);
      await t.tap(find.text('转换所选 2 本'));
      await until(() => find.text('转换问题摘要').evaluate().isNotEmpty);
      expect(find.text('继续转换'), findsOneWidget);
      library.checkBooks(
        repairIds,
        false,
      ); // Does not redefine the prepared batch.
      await t.tap(find.text('前往处理').first);
      await until(()=>find.text('返回转换并重新检查').evaluate().isNotEmpty && find.byType(LinearProgressIndicator).evaluate().isEmpty);
      expect(find.text('返回转换并重新检查'), findsOneWidget);
      await t.tap(find.text('返回转换并重新检查'));
      await until(() => find.byType(ConversionPage).evaluate().isNotEmpty);
      final conversion = t.widget<ConversionPage>(find.byType(ConversionPage));
      await until(
        () => !conversion.session.busy && conversion.draft.reviewing.value,
      );
      expect(conversion.draft.selected, repairIds);
      expect(conversion.draft.format, 'MOBI');
      expect(conversion.draft.directory, '$root/output');
      expect(conversion.session.request!.books.toSet(), repairIds);
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
