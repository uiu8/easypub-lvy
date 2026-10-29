import 'dart:io';

import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';

import 'dart:convert';

import 'package:easypub_desktop/desk/controls/controls.dart';
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

import 'library_removal_test.dart' as setup;

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
        QuickConversionChoice? choice;
        await t.pumpWidget(
          MaterialApp(
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
    'actual app quick entry outputs selected books in every configured format with saved defaults and no duplicate queue',
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
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 4000; i++) {
          await t.pump(const Duration(milliseconds: 20));
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        fail(
          'quick operation did not settle: ${state.outputs.tasks.map((o) => o.phase).join(',')}',
        );
      }

      await until(
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await t.pumpAndSettle();
      final router = GoRouter.of(t.element(find.byType(LibraryPage)));

      Finder footerAction(String label) => find.descendant(
        of: find.byKey(const ValueKey('workspace-output-bar')),
        matching: find.widgetWithText(TextButton, label),
      );
      bool enabled(Finder action) =>
          action.evaluate().isNotEmpty &&
          t.widget<TextButton>(action).onPressed != null;
      final rangeMenu = find.byWidgetPredicate(
        (widget) => widget is DeskMenuButton<bool> && widget.tooltip == '转换范围',
      );
      await until(
        () =>
            rangeMenu.evaluate().isNotEmpty &&
            t.widget<DeskMenuButton<bool>>(rangeMenu).enabled,
      );
      await t.tap(find.byTooltip('转换范围'));
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: find.byKey(deskMenuPanelKey),
          matching: find.text('已勾选 2 本'),
        ),
      );
      await t.pumpAndSettle();

      for (final format in [
        'EPUB',
        'AZW3',
        'MOBI',
        if (Platform.environment['EASYPUB_TEST_BOKAI'] != null) 'KFX',
      ]) {
        router.go('/');
        await t.pumpAndSettle();
        await until(() => !state.globalSettingsBusy);
        bool? saved;
        Object? saveError;
        library
            .savePatch({
              'output_format': format,
              'kfx_converter': Platform.environment['EASYPUB_TEST_BOKAI'],
              'output_directory': '',
              'generate_cover': true,
              'check_before_conversion': false,
              // V109：概览默认从左栏收起；后面要点左栏的“概览”。
              'nav_hidden_pages': <String>[],
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
              enabled(footerAction('转换所选 2 本')) &&
              find
                  .byKey(ValueKey('quick-format-$format'))
                  .evaluate()
                  .isNotEmpty,
        );
        final before = state.outputs.tasks.length;
        final action = t.widget<TextButton>(footerAction('转换所选 2 本'));
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
          reason: state.outputs.tasks
              .skip(before)
              .map((o) => o.phase)
              .join(','),
        );
        for (final task in state.outputs.tasks.skip(before)) {
          expect(File(task.outputPath).existsSync(), true);
          expect(task.format, format);
        }
        expect(library.selection.value.selected, ids);
        router.go('/');
        await t.pumpAndSettle();
        await until(() => enabled(footerAction('转换所选 2 本')));
      }
      final files = Directory('$root/output').listSync();
      expect(
        files,
        hasLength(Platform.environment['EASYPUB_TEST_BOKAI'] == null ? 6 : 8),
      );
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
          .savePatch({
            'check_before_conversion': true,
            'output_format': 'EPUB',
            'output_directory': '$root/repaired-output',
          })
          .then((v) => settingsSaved = v);
      await until(() => settingsSaved != null);
      expect(settingsSaved, true);
      await until(
        () =>
            enabled(footerAction('转换所选 2 本')) &&
            find
                .byKey(const ValueKey('quick-format-EPUB'))
                .evaluate()
                .isNotEmpty,
      );
      await t.tap(footerAction('转换所选 2 本'));
      await until(() => find.text('转换问题摘要').evaluate().isNotEmpty);
      expect(find.text('继续转换'), findsOneWidget);
      library.checkBooks(
        repairIds,
        false,
      ); // Does not redefine the prepared batch.
      await t.tap(find.text('前往处理').first);
      await until(
        () =>
            find.text('返回转换并重新检查').evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(find.text('返回转换并重新检查'), findsOneWidget);
      await t.tap(find.text('概览'));
      await until(
        () => router.routeInformationProvider.value.uri.path.endsWith(
          '/overview',
        ),
      );
      expect(find.text('返回转换并重新检查'), findsOneWidget);
      await t.tap(find.text('书籍信息与封面').first);
      await until(
        () => router.routeInformationProvider.value.uri.path.endsWith(
          '/information',
        ),
      );
      expect(find.text('返回转换并重新检查'), findsOneWidget);
      await t.tap(find.byTooltip('页面导航'));
      await t.pumpAndSettle();
      await t.tap(find.text('章节编辑').last);
      await until(
        () => router.routeInformationProvider.value.uri.path.endsWith(
          '/chapters',
        ),
      );
      expect(find.text('返回转换并重新检查'), findsOneWidget);
      final chapterMore = find.descendant(
        of: find.byTooltip('更多章节操作'),
        matching: find.byType(TextButton),
      );
      await until(() => enabled(chapterMore));
      await t.tap(chapterMore);
      await t.pumpAndSettle();
      await t.tap(find.text('参考目录修复'));
      await until(
        () =>
            router.routeInformationProvider.value.uri.path.endsWith('/catalog'),
      );
      expect(find.text('返回转换并重新检查'), findsOneWidget);
      // V3：参考目录页的返回入口由“自助修复”更名为“返回章节编辑”（CH-173）。
      await t.tap(find.text('返回章节编辑'));
      await until(
        () => router.routeInformationProvider.value.uri.path.endsWith(
          '/chapters',
        ),
      );
      expect(find.text('返回转换并重新检查'), findsOneWidget);
      final repairedId = repairIds.firstWhere((id) => !ids.contains(id));
      final sourceBefore = bad.readAsBytesSync();
      var editDone = false;
      () async {
        final chapters = library.openChapters(repairedId);
        final page = await chapters.read(0);
        final gap = page.nodes.singleWhere((n) => n.title.contains('第三章'));
        await chapters.rename(page, gap.id, '第二章 修复完成');
        final updated = await chapters.read(0);
        expectSync(updated.nodes.any((n) => n.title == '第二章 修复完成'), true);
        editDone = true;
      }();
      await until(() => editDone);
      t.printToConsole('repair45 edit done');
      await t.tap(find.text('返回转换并重新检查'));
      await until(() => find.byType(ConversionPage).evaluate().isNotEmpty);
      final conversion = t.widget<ConversionPage>(find.byType(ConversionPage));
      await until(
        () =>
            !conversion.session.busy &&
            conversion.draft.reviewing.value &&
            (conversion.session as LegacyConversionSession).exposed != null &&
            conversion.session.isCurrent(
              (conversion.session as LegacyConversionSession).exposed!,
            ),
      );
      t.printToConsole('repair45 preview done');
      expect(conversion.draft.selected, repairIds);
      expect(conversion.draft.format, 'EPUB');
      expect(conversion.draft.directory, '$root/repaired-output');
      expect(conversion.session.request!.books.toSet(), repairIds);
      final beforeRepairOutput = state.outputs.tasks.length;
      await until(() => enabled(footerAction('确认转换 2 本')));
      await t.tap(footerAction('确认转换 2 本'));
      t.printToConsole('repair45 commit clicked');
      await until(
        () =>
            !conversion.session.busy &&
            state.outputs.tasks.length == beforeRepairOutput + 2 &&
            state.outputs.tasks
                .skip(beforeRepairOutput)
                .every((o) => o.terminal),
      );
      final newTasks = state.outputs.tasks.skip(beforeRepairOutput).toList();
      expect(newTasks.every((o) => o.phase == 'complete'), true);
      expect(newTasks.map((o) => o.bookId).toSet(), repairIds);
      expect(bad.readAsBytesSync(), sourceBefore);
      final repairedOutput = newTasks.singleWhere(
        (o) => o.bookId == repairedId,
      );
      t.printToConsole('repair45 output done');
      final checked = await t.runAsync(
        () => Process.run(Platform.environment['EASYPUB_TEST_PYTHON']!, [
          '-X',
          'utf8',
          '-c',
          'import zipfile,sys,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); text="\\n".join("".join(E.fromstring(z.read(n)).itertext()) for n in z.namelist() if n.endswith(".xhtml")); assert "第二章 修复完成" in text; assert "第三章 跳号" not in text; assert "正文甲" in text and "正文乙" in text; print("repaired chapter and preserved body verified")',
          repairedOutput.outputPath,
        ]),
      );
      expect(checked!.exitCode, 0, reason: checked.stderr.toString());
      File('$root/repair-output-evidence.json').writeAsStringSync(
        jsonEncode({
          'source_unchanged': true,
          'book_ids': repairIds.toList(),
          'outputs': newTasks
              .map((o) => {'path': o.outputPath, 'receipt': o.receipt})
              .toList(),
          'content_verification': checked.stdout.toString(),
        }),
      );
      // Current-book conversion does not replace or borrow the batch selection.
      await t.runAsync(
        () => library.savePatch({
          'output_directory': '$root/current-only',
          'output_format': 'EPUB',
        }),
      );
      library.selectBook(repairedId);
      final selectionBefore = Set<String>.of(library.selection.value.selected);
      final currentStart = state.outputs.tasks.length;
      router.go('/');
      await t.pumpAndSettle();
      await until(() => enabled(footerAction('转换当前书')));
      await t.tap(footerAction('转换当前书'));
      await until(
        () =>
            state.outputs.tasks.length == currentStart + 1 &&
            state.outputs.tasks.last.terminal,
      );
      expect(state.outputs.tasks.last.phase, 'complete');
      expect(state.outputs.tasks.last.bookId, repairedId);
      expect(library.selection.value.selected, selectionBefore);
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
