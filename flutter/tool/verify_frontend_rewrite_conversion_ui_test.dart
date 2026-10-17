import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_output_history_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/output_task.dart';
import 'package:easypub_desktop/desk/conversion/output_history_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/infrastructure/native_conversion_desktop.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';

class _Picker implements BookFilePicker {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Library extends LegacyLibraryAdapter {
  _Library(PrototypeState state)
    : conversion = LegacyConversionSession(state),
      super(backend: state);
  late LegacyConversionSession conversion;
  @override
  ConversionSession openConversion() => conversion;

  @override
  Future<bool> load() async => true;
}

class _Desktop implements ConversionDesktop {
  final openedFiles = <String>[];
  @override
  Future<void> openOutput(String path) async {
    openedFiles.add(path);
  }

  String? choice;
  final opened = <String>[];
  @override
  Future<String?> bundledConverter() async =>
      r'D:\portable\converters\kindling.exe';
  @override
  Future<String?> chooseConverter() async => choice;
  @override
  Future<void> openDirectory(String path) async {
    opened.add(path);
  }
}

void main() {
  test('portable discovery is executable-relative; directory launch validates path', () async {
    final parent = Directory(
      '../artifacts/frontend-rewrite/conversion-desktop',
    );
    await parent.create(recursive: true);
    final root = await parent.createTemp('portable-');
    final opened = <String>[];
    final desktop = NativeConversionDesktop(
      executablePath: '${root.absolute.path}/EasyPub.exe',
      launchDirectory: (path) async {
        opened.add(path);
      },
    );
    await File('${root.path}/kindling.exe').writeAsBytes([0]);
    expect(await desktop.bundledConverter(), isNull);
    await Directory('${root.path}/converters').create();
    final bundled = File('${root.absolute.path}/converters/kindling.exe');
    await bundled.writeAsBytes([0]);
    expect(await desktop.bundledConverter(), bundled.absolute.path);
    await expectLater(desktop.openDirectory('relative'), throwsFormatException);
    await expectLater(
      desktop.openDirectory('${root.absolute.path}/missing'),
      throwsFormatException,
    );
    expect(opened, isEmpty);
    await desktop.openDirectory(root.absolute.path);
    expect(opened, [root.absolute.path]);
  });
  testWidgets(
    'rewrite sidebar conversion checks cancels previews then commits EPUB',
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
      final root = Directory('../artifacts/frontend-rewrite/conversion-ui');
      final backend = PrototypeState(
        settingsDirectory:
            '${root.absolute.path}/settings-${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(backend.dispose);
      late Directory output;
      await tester.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            File('../target/release/easypub_bridge.dll').absolute.path,
          ),
        );
        await root.create(recursive: true);
        for (final entry in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(entry.key)..addFont(
                File(entry.value).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
        output = await root.createTemp('output-');
        final source = File('${root.path}/窗口样书.txt');
        await source.writeAsString('第一章 来信\n河边来了信。\n第二章 夜渡\n夜色深了。\n');
        await backend.importBookOutcome(source.absolute.path);
      });
      final library = _Library(backend);
      library.conversion.dispose();
      final releaseCommit = Completer<void>();
      var commitStarted = false;
      String? collideSource, occupiedPath;
      library.conversion = LegacyConversionSession(
        backend,
        epubCall: (request) async {
          if (request['op'] == 'commit') {
            commitStarted = true;
            if (!releaseCommit.isCompleted) await releaseCommit.future;
            if (request['source_path'] == collideSource) {
              occupiedPath = request['output_path'] as String;
              await File(occupiedPath!).writeAsString('existing file wins');
              collideSource = null;
            }
          }
          return (jsonDecode(
            await api.epubExportText(requestJson: jsonEncode(request)),
          ) as Map).cast<String, dynamic>();
        },
      );
      addTearDown(() {
        if (!releaseCommit.isCompleted) releaseCommit.complete();
      });
      addTearDown(library.dispose);
      library.checkBook(backend.currentId, true);
      await tester.runAsync(() async {
        final info = library.openBookInformation(backend.currentId);
        await info.apply(
          await info.preview({'author': '测试作者', 'language': 'zh-CN'}),
        );
        info.dispose();
      });
      final desktop = _Desktop();
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: RewriteApp(
            library: library,
            picker: _Picker(),
            conversionDesktop: desktop,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('转换'));
      // The production shell may keep a status ticker alive while the
      // conversion session hydrates. Wait for the target page itself instead
      // of requiring global animation quiescence.
      for (var i = 0; i < 100 && find.text('转换设置').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('转换设置'), findsOneWidget);
      for (var i = 0; i < 100 && find.text('AZW3').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tap(find.text('AZW3'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('转换高级设置'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .last
            .controller!
            .text,
        r'D:\portable\converters\kindling.exe',
      );
      await tester.tap(find.text('浏览转换器'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .last
            .controller!
            .text,
        r'D:\portable\converters\kindling.exe',
      );
      desktop.choice = r'D:\chosen\kindling.exe';
      await tester.tap(find.text('浏览转换器'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .last
            .controller!
            .text,
        desktop.choice,
      );
      await tester.tap(find.text('采用设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('EPUB'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成后打开输出文件夹'));
      await tester.pump();
      await tester.enterText(
        find.byType(TextField).first,
        output.absolute.path,
      );
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 400 && !ready(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(
          ready(),
          true,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data)
              .join('\n'),
        );
      }

      Future<void> settleLoadedPage() async {
        await tester.pump();
        await waitFor(
          () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
        );
        await tester.pumpAndSettle();
      }

      // Unknown language falls back for export without changing book metadata.
      await tester.runAsync(() async {
        final info = library.openBookInformation(backend.currentId);
        await info.apply(await info.preview({'language': 'und'}));
        info.dispose();
      });
      await tester.tap(find.text('浏览'));
      await tester.pump();
      await waitFor(
        () =>
            find.text('使用此文件夹').evaluate().isNotEmpty &&
            tester
                    .widget<TextButton>(
                      find.widgetWithText(TextButton, '使用此文件夹'),
                    )
                    .onPressed !=
                null,
      );
      await tester.tap(find.text('使用此文件夹'));
      await tester.pump();
      await waitFor(() => find.byType(Dialog).evaluate().isEmpty);
      expect(library.conversion.outputs, isEmpty);
      expect(find.textContaining(RegExp(r'^确认(保留并)?转换$')), findsNothing);
      await tester.tap(find.text('检查书稿'));
      await tester.pump();
      await waitFor(
        () =>
            find.textContaining(RegExp(r'^确认(保留并)?转换$')).evaluate().isNotEmpty,
      );
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('转换前自动检查'), findsOneWidget);
      await settleLoadedPage();
      await tester.runAsync(() async {
        final screenshot =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
        await File('${root.path}/preflight.png')
            .writeAsBytes(png!.buffer.asUint8List());
        screenshot.dispose();
      });

      await tester.runAsync(() async {
        expect(await output.list().isEmpty, true);
      });
      await tester.runAsync(() async {
        final info = library.openBookInformation(backend.currentId);
        await info.apply(await info.preview({'author': '修订作者'}));
        info.dispose();
      });
      await tester.pump();
      expect(find.text('检查结果已失效'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.ancestor(
                of: find.textContaining(RegExp(r'^确认(保留并)?转换$')),
                matching: find.byType(TextButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('返回设置'));
      await settleLoadedPage();
      await tester.tap(find.text('检查书稿'));
      await tester.pump();
      await waitFor(
        () =>
            find.textContaining(RegExp(r'^确认(保留并)?转换$')).evaluate().isNotEmpty,
      );
      expect(find.text('已阅读提醒，确认继续输出'), findsNothing);
      await tester.tap(find.textContaining(RegExp(r'^确认(保留并)?转换$')));
      await tester.pump();
      await waitFor(() => commitStarted);
      await tester.tap(find.text('任务'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('本次转换'), findsOneWidget);
      expect(find.text('正在生成'), findsWidgets);
      expect(library.conversion.busy, true);
      expect(library.conversion.disposed, false);
      await tester.tap(find.text('继续添加'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.widget<TextField>(find.byType(TextField).first).enabled,
        false,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        output.absolute.path,
      );
      await tester.tap(find.text('任务'));
      await tester.pump(const Duration(milliseconds: 500));
      releaseCommit.complete();
      await waitFor(() => library.conversion.outputs.any((o) => o.complete));
      await waitFor(() => desktop.opened.isNotEmpty);
      expect(desktop.opened, [output.absolute.path]);
      await tester.tap(find.text('已完成 1'));
      await tester.pump();
      await waitFor(
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await settleLoadedPage();
      expect(find.text('打开成品目录'), findsOneWidget);
      await tester.runAsync(() async {
        final screenshot =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
        await File('${root.path}/tasks-complete.png')
            .writeAsBytes(png!.buffer.asUint8List());
        screenshot.dispose();
      });
      await tester.tap(find.text('成品验收'));
      await tester.pump();
      await waitFor(() => find.text('通过').evaluate().isNotEmpty);
      await settleLoadedPage();
      await waitFor(() => find.text('字段一致').evaluate().isNotEmpty);
      expect(find.textContaining('书名、作者、语言与本次转换回执中的预期一致'), findsOneWidget);
      expect(find.text('待核验'), findsOneWidget);
      expect(find.bySemanticsLabel('实际成品封面'), findsOneWidget);
      await waitFor(
        () => tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
      );
      await tester.pump();
      expect(find.text('待验收'), findsOneWidget);
      await tester.tap(find.text('打开成品'));
      await tester.pump();
      expect(desktop.openedFiles, [library.conversion.outputs.single.path]);
      await tester.runAsync(() async {
        final screenshot =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
        await File('${root.path}/output-acceptance.png')
            .writeAsBytes(png!.buffer.asUint8List());
        screenshot.dispose();
      });
      await tester.tap(find.text('返回转换任务'));
      await settleLoadedPage();
      await tester.tap(find.text('失败 0'));
      await settleLoadedPage();
      expect(find.text('此分类暂无任务。'), findsOneWidget);
      await tester.tap(find.text('继续添加'));
      await settleLoadedPage();
      await tester.enterText(
        find.byType(TextField).first,
        '${output.absolute.path}/different',
      );
      await tester.tap(find.text('打开输出文件夹'));
      await settleLoadedPage();
      expect(desktop.opened, [output.absolute.path, output.absolute.path]);
      await tester.tap(find.text('任务'));
      await settleLoadedPage();
      await tester.tap(find.text('继续添加'));
      await settleLoadedPage();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '${output.absolute.path}/different',
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, '完成后打开输出文件夹'),
            )
            .value,
        true,
      );
      await tester.runAsync(() async {
        final files = await output
            .list()
            .where((f) => f.path.endsWith('.epub'))
            .toList();
        expect(files.length, 1);
        expect(await File(files.single.path).length(), greaterThan(100));
      });
      final firstId = backend.currentId;
      late String secondId;
      await tester.runAsync(() async {
        final source = File('${output.path}/失败样书.txt');
        await source.writeAsString('第一章 清晨\n风吹过河面。\n第二章 午后\n人们回来了。\n');
        await backend.importBookOutcome(source.absolute.path);
        secondId = backend.currentId;
        final info = library.openBookInformation(secondId);
        await info.apply(
          await info.preview({'author': '测试作者', 'language': 'zh-CN'}),
        );
        info.dispose();
        collideSource = source.absolute.path;
        final mixed = await library.conversion.preview(
          ConversionRequest(
            books: [firstId, secondId],
            directory: output.absolute.path,
            format: 'EPUB',
          ),
        );
        final result = await library.conversion.commit(
          mixed,
          acknowledgeWarnings: true,
        );
        expect(result.first.complete, true);
        expect(result.last.failed, true);
      });
      final successfulTaskCount = backend.outputs.tasks
          .where((t) => t.bookId == firstId)
          .length;
      await tester.tap(find.text('任务'));
      await settleLoadedPage();
      await tester.tap(find.text('失败 1'));
      await settleLoadedPage();
      expect(find.text('重试此项'), findsOneWidget);
      await tester.tap(find.text('重试本批次失败项'));
      await waitFor(() => find.text('无法按原配置重试').evaluate().isNotEmpty);
      expect(File(occupiedPath!).readAsStringSync(), 'existing file wins');
      expect(
        backend.outputs.tasks.where((t) => t.bookId == firstId).length,
        successfulTaskCount,
      );
      final newOutput = Directory('${output.path}/reconfigured');
      await tester.runAsync(() async {
        await newOutput.create();
        expect(
          await library.savePatch({
            'output_directory': newOutput.absolute.path,
            'output_format': 'EPUB',
            'check_before_conversion': false,
          }),
          true,
        );
      });
      await tester.tap(find.text('使用当前书稿重新配置'));
      await waitFor(() => find.text('本次输出 · 1本书').evaluate().isNotEmpty);
      await settleLoadedPage();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        newOutput.absolute.path,
      );
      expect(find.textContaining('使用当前默认设置创建新批次'), findsOneWidget);
      expect(find.text('本次输出 · 1本书'), findsOneWidget);
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .where((c) => c.value == true)
            .length,
        1,
      );
      await tester.tap(find.text('开始转换'));
      await tester.pump();
      await waitFor(
        () =>
            library.conversion.outputs.isNotEmpty &&
            library.conversion.outputs.single.complete,
      );
      expect(library.conversion.request!.books, [secondId]);
      expect(library.conversion.request!.runChecks, false);
      final retryPath = library.conversion.outputs.single.path;
      expect(
        backend.outputs.tasks.where((t) => t.bookId == firstId).length,
        successfulTaskCount,
      );
      await tester.runAsync(() async {
        expect(await File(retryPath).length(), greaterThan(100));
        expect(File(occupiedPath!).readAsStringSync(), 'existing file wins');
      });
      await waitFor(() => !library.conversion.busy);
      await tester.tap(find.text('任务'));
      await settleLoadedPage();
      // The failed attempt is now historical: the current batch succeeded.
      expect(library.conversion.outputs.every((o) => o.complete), true);
      expect(find.text('当前及最近任务'), findsOneWidget);
      await tester.tap(find.text('失败 1'));
      await settleLoadedPage();
      await tester.tap(find.text('重试此项'));
      await settleLoadedPage();
      await waitFor(() => find.text('无法按原配置重试').evaluate().isNotEmpty);
      await tester.tap(find.text('使用当前书稿重新配置'));
      await waitFor(
        () => find.textContaining('使用当前默认设置创建新批次').evaluate().isNotEmpty,
      );
      await settleLoadedPage();
      expect(find.textContaining('使用当前默认设置创建新批次'), findsOneWidget);
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .where((c) => c.value == true),
        hasLength(1),
      );
      await tester.tap(find.text('任务'));
      await settleLoadedPage();
      await tester.tap(find.text('转换历史'));
      await tester.pump();
      await waitFor(
        () =>
            find.text('核验文件').evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await settleLoadedPage();
      await tester.tap(find.text('核验文件'));
      await tester.pump();
      await waitFor(
        () => find.textContaining('核对时文件内容与导出回执一致').evaluate().isNotEmpty,
      );
      await tester.runAsync(() async {
        final historyBackend = PrototypeState(
          settingsDirectory: backend.settingsDirectory,
        );
        try {
          final history = LegacyOutputHistoryService(historyBackend);
          await history.load();
          final record = history.page(0).firstWhere((r) => r.path == retryPath);
          expect(record.restored, true);
          expect(record.verification, isEmpty);
          expect(history.page(0).length, lessThanOrEqualTo(50));
          expect(() => history.page(-1), throwsArgumentError);
          expect(() => history.page(0, limit: 51), throwsArgumentError);
          await expectLater(
            history.verify('nonexistent'),
            throwsFormatException,
          );
          await history.verify(record.id);
          expect(
            history.page(0).firstWhere((r) => r.id == record.id).verification,
            contains('与导出回执一致'),
          );
          final file = File(retryPath),
              bytes = await File(retryPath).readAsBytes();
          try {
            await file.writeAsBytes([...bytes, 1, 2, 3]);
            await history.verify(record.id);
            expect(
              history.page(0).firstWhere((r) => r.id == record.id).verification,
              contains('与导出回执不一致'),
            );
            final inspected = await history.inspectPackage(record.id);
            expect(inspected.status, 'failed');
            expect(inspected.cover, isNull);
            expect(await file.length(), bytes.length + 3);
          } finally {
            await file.writeAsBytes(bytes);
          }
        } finally {
          historyBackend.dispose();
        }
      });
      late String pendingId;
      final recoveryPath = '${output.absolute.path}/recovery.epub';
      await tester.runAsync(() async {
        final finished = backend.outputs.tasks.last;
        final pending = OutputTask(
          bookId: finished.bookId,
          title: '恢复测试',
          sourceId: finished.sourceId,
          revision: finished.revision,
          format: finished.format,
          outputPath: recoveryPath,
        );
        await backend.outputs.persist(pending);
        pendingId = pending.taskId;
        final book = backend.shelf.books.firstWhere(
          (b) => b.id == finished.bookId,
        );
        final request = {
          'op': 'preview',
          'publication': backend.publicationRequest(finished.bookId),
          'source_path': book.source!.path,
          'output_path': recoveryPath,
        };
        final preview = jsonDecode(
          await api.epubExportText(requestJson: jsonEncode(request)),
        ) as Map;
        await api.epubExportText(
          requestJson: jsonEncode({
            ...request,
            'op': 'commit',
            'confirmed': true,
            'plan_id': preview['plan_id'],
          }),
        );
      });
      final recoveryBackend = PrototypeState(
        settingsDirectory: backend.settingsDirectory,
      );
      addTearDown(recoveryBackend.dispose);
      final history = LegacyOutputHistoryService(recoveryBackend);
      await tester.runAsync(() async {
        await history.load();
        final cancelled = await history.previewRecovery(pendingId);
        expect(cancelled.publishesStaged, false);
        history.cancelRecovery(cancelled);
        await expectLater(history.recover(cancelled), throwsFormatException);
        final stale = await history.previewRecovery(pendingId);
        final file = File(recoveryPath),
            bytes = await File(recoveryPath).readAsBytes();
        try {
          await file.writeAsBytes([...bytes, 4]);
          await expectLater(history.recover(stale), throwsFormatException);
          expect(await file.length(), bytes.length + 1);
          expect(recoveryBackend.outputs.tasks.last.phase, 'interrupted');
        } finally {
          await file.writeAsBytes(bytes);
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: OutputHistoryPage(
              history: history,
              desktop: desktop,
              onBack: () {},
            ),
          ),
        ),
      );
      await waitFor(
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await settleLoadedPage();
      await tester.tap(find.text('预览恢复'));
      await tester.pump();
      await waitFor(() => find.text('确认恢复').evaluate().isNotEmpty);
      await tester.tap(find.text('取消'));
      await settleLoadedPage();
      expect(recoveryBackend.outputs.tasks.last.phase, 'interrupted');
      await tester.tap(find.text('预览恢复'));
      await tester.pump();
      await waitFor(() => find.text('确认恢复').evaluate().isNotEmpty);
      await tester.tap(find.text('确认恢复'));
      await tester.pump();
      await waitFor(
        () =>
            recoveryBackend.outputs.tasks.last.phase == 'complete' &&
            !recoveryBackend.outputs.tasks.last.verifying,
      );
      await tester.runAsync(() async {
        final reopened = PrototypeState(
          settingsDirectory: backend.settingsDirectory,
        );
        try {
          await reopened.outputs.loadHistory();
          expect(reopened.outputs.tasks.last.phase, 'complete');
          expect(reopened.outputs.tasks.last.receipt, isNotNull);
        } finally {
          reopened.dispose();
        }
      });
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
