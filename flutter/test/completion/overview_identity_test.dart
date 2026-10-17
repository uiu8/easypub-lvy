import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:go_router/go_router.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_book_check_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/library/book_overview_page.dart';

class NoPicker extends Fake implements BookFilePicker {}

class ObservedChecks extends LegacyBookCheckSession {
  ObservedChecks(super.backend, super.bookId, this.calls);
  final List<String> calls;
  @override
  Future<BookCheckReport> inspect() {
    calls.add(bookId);
    return super.inspect();
  }
}

class ObservedLibrary extends LegacyLibraryAdapter {
  ObservedLibrary(this.state) : super(backend: state);
  final PrototypeState state;
  final opened = <String>[], calls = <String>[];
  @override
  BookCheckSession openChecks(String id) {
    opened.add(id);
    return ObservedChecks(state, id, calls);
  }
}

void main() {
  testWidgets(
    'overview checks follow book identity through repeated route changes',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      late PrototypeState backend;
      late ObservedLibrary library;
      late String a, b;
      await tester.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            File(
              Platform.environment['EASYPUB_TEST_DLL'] ??
                  '../target/release/easypub_bridge.dll',
            ).absolute.path,
          ),
        );
        for (final font in {
          'Microsoft YaHei': r'C:\Windows\Fonts\msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(font.key)..addFont(
                File(font.value)
                    .readAsBytes()
                    .then((b) => b.buffer.asByteData()),
              ))
              .load();
        }
        final tmp = await Directory.systemTemp.createTemp('easypub-ui-audit-');
        backend = PrototypeState(settingsDirectory: '${tmp.path}/settings');
        library = ObservedLibrary(backend);
        await library.load();
        for (final entry in {
          '甲书': '第一章 甲章\n甲正文\n第一章 甲章\n\n第二章 甲尾\n甲末\n',
          '乙书': '第一章 乙章\n乙正文\n',
        }.entries) {
          final file = File('${tmp.path}/${entry.key}.txt');
          await file.writeAsString(entry.value);
          expect(
            (await library.importFiles([file.path])).single.succeeded,
            true,
          );
        }
        a = library.books.value.firstWhere((v) => v.title == '甲书').id;
        b = library.books.value.firstWhere((v) => v.title == '乙书').id;
        library.opened.clear();
        library.calls.clear();
      });
      Future<void> settle() async {
        for (var i = 0; i < 220; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (i > 15 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            break;
          }
        }
        expect(tester.takeException(), isNull);
      }

      final key = GlobalKey();
      library.selectBook(a);
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: RewriteApp(
            library: library,
            picker: NoPicker(),
            initialLocation: '/books/${Uri.encodeComponent(a)}/overview',
          ),
        ),
      );
      await settle();
      final router = GoRouter.of(tester.element(find.byType(BookOverviewPage)));
      library.selectBook(b);
      router.go('/books/${Uri.encodeComponent(b)}/overview');
      await settle();
      expect(
        tester.widget<BookOverviewPage>(find.byType(BookOverviewPage)).bookId,
        b,
      );
      await tester.ensureVisible(find.text('检查本书').last);
      await tester.tap(find.text('检查本书').last);
      await settle();
      expect(
        library.calls.last,
        b,
        reason: 'Visible book and check session must agree.',
      );
      library.selectBook(a);
      router.go('/books/${Uri.encodeComponent(a)}/overview');
      await settle();
      await tester.ensureVisible(find.text('检查本书').last);
      await tester.tap(find.text('检查本书').last);
      await settle();
      expect(library.calls, [b, a]);
      expect(library.opened, [a, b, a]);
      router.go('/');
      await settle();
      library.removeBooks({a, b});
      await tester.pump();
      expect(library.selection.value.current, isNull);
      library.undoBookRemoval();
      library.selectBook(b);
      await tester.pump();
      await tester.tap(find.text('概览'));
      await settle();
      expect(
        tester.widget<BookOverviewPage>(find.byType(BookOverviewPage)).bookId,
        b,
      );
      library.selectBook(a);
      for (final scale in [1.0, 1.3]) {
        await tester.runAsync(() => library.savePatch({'ui_scale': scale}));
        for (final route in [
          '/',
          '/folders',
          '/settings',
          '/tasks',
          '/history',
          '/conversion',
          '/books/${Uri.encodeComponent(a)}/overview',
          '/books/${Uri.encodeComponent(a)}/checks',
          '/books/${Uri.encodeComponent(a)}/cleanup',
          '/books/${Uri.encodeComponent(a)}/chapters',
          '/books/${Uri.encodeComponent(a)}/information',
          '/books/${Uri.encodeComponent(a)}/layout',
          '/books/${Uri.encodeComponent(a)}/resources',
        ]) {
          router.go(route);
          await settle();
          expect(find.textContaining('工作台  /'), findsNothing);
          expect(find.textContaining('书库  /'), findsNothing);
          final header = find.byKey(const ValueKey('workspace-page-header'));
          expect(header, findsOneWidget, reason: route);
          // V1：页名移入 40 逻辑像素高的标题栏面包屑，不再占用独立页头。
          expect(
            tester.getRect(header).bottom,
            lessThanOrEqualTo(40 * scale.clamp(1.0, 1.5)),
            reason: route,
          );
          final captures = Platform.environment['EASYPUB_SCENE_CAPTURE'];
          if (captures != null) {
            await tester.runAsync(() async {
              await Directory(captures).create(recursive: true);
              final image =
                  await (key.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final name = route == '/' ? 'library' : route.split('/').last;
              await File('$captures/$name-$scale.png')
                  .writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        }
      }
      router.go('/');
      await settle();
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/header59-library.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      library.dispose();
      backend.dispose();
    },
  );
}
