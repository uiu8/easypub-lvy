import 'dart:convert';
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

class Picker implements BookFilePicker {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'real history metadata layout chapters stale undo project reopen and UI',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      final root = Directory('../artifacts/frontend-rewrite/change-history');
      late Directory run;
      late PrototypeState backend;
      late LegacyLibraryAdapter library;
      late String id;
      late File source;
      const original = '第一章 来信\n河边来信。\n第二章 夜渡\n天色暗了。\n';
      await tester.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            File('../target/release/easypub_bridge.dll').absolute.path,
          ),
        );
        await root.create(recursive: true);
        run = await root.createTemp('run-');
        for (final item in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(item.key)..addFont(
                File(item.value).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
        backend = PrototypeState(
          settingsDirectory: '${run.absolute.path}/settings',
        );
        library = LegacyLibraryAdapter(backend: backend);
        source = File('${run.path}/长河照影.txt');
        await source.writeAsString(original);
        await backend.importBookOutcome(source.absolute.path);
        id = backend.currentId;
        var info = library.openBookInformation(id);
        await info.apply(
          await info.preview({'author': '林间客', 'language': 'zh-CN'}),
        );
        info.dispose();
        final layout = library.openLayout(id);
        await layout.apply(await layout.preview({'line_height': 2.0}));
        layout.dispose();
        final chapters = library.openChapters(id);
        final page = await chapters.read(0);
        await chapters.rename(page, page.nodes.first.id, '第一章 河边来信');
        final history = library.openChangeHistory();
        final chapterRecord = history
            .records(id)
            .firstWhere((r) => r.domain == '章节');
        final chapterDetail = history.detail(chapterRecord);
        final frozenHistory = jsonEncode(backend.manuscript.effectiveHistories[id]);
        final trees = await history.chapterTrees(chapterDetail, 0);
        expect(trees.before.first.title, '第一章 来信');
        expect(trees.after.first.title, '第一章 河边来信');
        expect(trees.before.first.id, trees.after.first.id);
        final focused = await history.chapterTrees(
          chapterDetail,
          30,
          entryId: trees.before.first.id,
        );
        expect(focused.beforeOffset, 0);
        expect(focused.afterOffset, 0);
        expect(focused.beforeFound, isTrue);
        expect(focused.afterFound, isTrue);
        expect(focused.entryId, trees.before.first.id);
        final missing = await history.chapterTrees(
          chapterDetail,
          0,
          entryId: 'missing',
        );
        expect(missing.beforeFound, isFalse);
        expect(missing.afterFound, isFalse);
        expect(jsonEncode(backend.manuscript.effectiveHistories[id]), frozenHistory);
        final beyond = await history.chapterTrees(chapterDetail, 30);
        expect(beyond.before, isEmpty);
        expect(beyond.after, isEmpty);
        expect(await source.readAsString(), original);

        expect(
          history.records(id).map((r) => r.category),
          containsAll(['章节', '排版', '书籍信息']),
        );
        final old = history.detail(
          history.records(id).firstWhere((r) => r.category == '排版'),
        );
        info = library.openBookInformation(id);
        await info.apply(await info.preview({'author': '另一作者'}));
        info.dispose();
        await expectLater(history.undo(old), throwsFormatException);
        await expectLater(
          history.chapterTrees(chapterDetail, 0),
          throwsFormatException,
        );
        final latest = history.detail(
          history
              .records(id)
              .firstWhere((r) => r.category == '书籍信息' && r.canUndo),
        );
        expect(
          latest.fields.any(
            (f) => f.label == '作者' && f.before == '林间客' && f.after == '另一作者',
          ),
          true,
        );
        await history.undo(latest);
        expect(backend.production.settings(id)['author'], '林间客');
        final chapter = history.detail(
          history.records(id).firstWhere((r) => r.domain == '章节'),
        );
        await history.undo(chapter);
        expect((await chapters.read(0)).nodes.first.title, '第一章 来信');
        final beforeCleanup = await chapters.read(0);
        await chapters.rename(
          beforeCleanup,
          beforeCleanup.nodes.first.id,
          '第一章 暂存标题',
        );
        final cleanup = library.openCleanup(id);
        final rules = jsonDecode(cleanup.settings) as Map<String, dynamic>;
        (rules['pipeline'] as List).add({'kind': 'remove_ad_lines'});
        await cleanup.apply(await cleanup.preview(jsonEncode(rules)));
        final incompatible = history.detail(
          history.records(id).firstWhere((r) => r.domain == '章节'),
        );
        final cursorBefore = backend.manuscript.effectiveHistories[id]!['cursor'];
        await expectLater(history.undo(incompatible), throwsFormatException);
        expect(backend.manuscript.effectiveHistories[id]!['cursor'], cursorBefore);
        final cleanupRecord = history.detail(
          history.records(id).firstWhere((r) => r.domain == '文本清理'),
        );
        expect(cleanupRecord.fields, isNotEmpty);
        await history.undo(cleanupRecord);
        expect(backend.cleanup.drafts.containsKey(id), false);
        cleanup.dispose();
        await history.undo(
          history.detail(
            history.records(id).firstWhere((r) => r.domain == '章节'),
          ),
        );
        expect(await source.readAsString(), original);
      });
      addTearDown(library.dispose);
      addTearDown(backend.dispose);
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: RewriteApp(library: library, picker: Picker()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录'));
      await tester.pump();
      for (
        var i = 0;
        i < 200 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('变更记录'), findsOneWidget);
      await tester.tap(find.text('修改排版'));
      await tester.pumpAndSettle();
      expect(find.text('修改前'), findsOneWidget);
      expect(find.text('修改后'), findsOneWidget);
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${root.path}/history.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('撤销此次修改'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(backend.production.settings(id)['line_height'], 2.0);
      await tester.tap(find.text('撤销此次修改'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认撤销'));
      await tester.pump();
      for (
        var i = 0;
        i < 400 &&
            (backend.production.settings(id)['line_height'] == 2.0 ||
                backend.production.busy);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(backend.production.settings(id)['line_height'], isNot(2.0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final path = '${run.absolute.path}/history.easypub.json';
        final saved = await library.saveProject(path);
        expect(saved.succeeded, true, reason: saved.message);
        final restored = PrototypeState(
          settingsDirectory: '${run.absolute.path}/reopened',
        );
        final reopened = LegacyLibraryAdapter(backend: restored);
        try {
          expect((await reopened.openProject(path)).succeeded, true);
          final records = reopened.openChangeHistory().records(
            restored.currentId,
          );
          expect(records.any((r) => r.category == '排版' && !r.applied), true);
          expect(records.any((r) => r.category == '书籍信息' && r.applied), true);
          expect(await source.readAsString(), original);
        } finally {
          reopened.dispose();
          restored.dispose();
        }
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
}
