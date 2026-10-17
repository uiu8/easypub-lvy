import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/checkpoint_dialog.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

import 'library_removal_test.dart' as fixtures;

import 'package:easypub_desktop/desk/tokens.dart';

class DelayedCheckpoint extends Fake
    implements ChapterSession, ChapterCheckpointSession {
  final ready = Completer<ChapterEditPreview>();
  int confirmed = 0;
  @override
  Future<ChapterEditPreview> previewCheckpoint(ChapterPage page) =>
      ready.future;
  @override
  Future<void> confirm(ChapterEditPreview preview) async {
    confirmed++;
  }
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  testWidgets(
    'cancel while checkpoint is preparing never commits during route dismissal',
    (t) async {
      final session = DelayedCheckpoint();
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ChapterCheckpointDialog(
                  session: session,
                  page: const ChapterPage([], 0, 0, 'guard'),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('生成并继续编辑'));
      await t.pump();
      await t.tap(find.text('取消'));
      session.ready.complete(const ChapterEditPreview());
      await t.pump();
      await t.pumpAndSettle();
      expect(session.confirmed, 0);
    },
  );

  testWidgets(
    'chapter page checkpoint preserves manuscript, undo and actionable UI',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.runAsync(() async {
        await (FontLoader('Microsoft YaHei')..addFont(
              File('C:/Windows/Fonts/msyh.ttc')
                  .readAsBytes()
                  .then((b) => b.buffer.asByteData()),
            ))
            .load();
        await (FontLoader('MaterialIcons')..addFont(
              File(
                'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
      });
      final fixture = (await t.runAsync(fixtures.fixture))!;
      final (state, library, _) = fixture;
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final id = library.books.value.first.id;
      await t.runAsync(() async {
        final session = library.openChapters(id);
        final page = await session.read(0);
        await session.confirm(
          await session.preview(
            page,
            RenameChapter(page.nodes.first.id, '第一章 保留编辑'),
          ),
        );
      });
      await t.runAsync(() async {
        final session = library.openChapters(id);
        final page = await session.read(0);
        for (var i = 0; i < 99; i++) {
          final current = await session.read(0);
          await session.confirm(
            await session.preview(
              current,
              RenameChapter(page.nodes.first.id, '第一章 保留编辑'),
            ),
          );
        }
      });
      await t.runAsync(() async {
        final session = library.openChapters(id);
        final page = await session.read(0);
        final history = jsonEncode(state.manuscript.effectiveHistories[id]);
        await expectLater(
          session.preview(page, RenameChapter(page.nodes.first.id, '超限不应修改')),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('检查点'),
            ),
          ),
        );
        expect(jsonEncode(state.manuscript.effectiveHistories[id]), history);
      });
      final capture = GlobalKey();
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: Desk.light.canvas,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: ChapterWorkspace(library: library, bookId: id),
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 300 && !ready(); i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
        }
        expect(ready(), true);
        await t.pumpAndSettle();
      }

      await waitFor(
        () =>
            find.text('第一章 保留编辑').evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(find.text('编辑记录较多，保存编辑快照后可继续编辑。'), findsOneWidget);
      final before = jsonEncode(state.manuscript.effectiveHistories[id]);
      await t.tap(find.text('保存编辑快照'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(jsonEncode(state.manuscript.effectiveHistories[id]), before);
      await t.tap(find.text('保存编辑快照'));
      await t.pumpAndSettle();
      await t.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/checkpoint65-chapters.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await t.tap(find.text('生成并继续编辑'));
      await waitFor(
        () =>
            state.manuscript.effectiveSelection(id)?['checkpoint'] != null &&
            find.byType(AlertDialog).evaluate().isEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(state.manuscript.effectiveSelection(id)!['actions'], isEmpty);
      expect(find.text('第一章 保留编辑'), findsWidgets);
      final checkpointCursor = state.manuscript.effectiveHistories[id]!['cursor'] as int;
      await t.tap(find.byTooltip('撤销'));
      await waitFor(
        () =>
            state.manuscript.effectiveHistories[id]!['cursor'] == checkpointCursor - 1 &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(find.text('第一章 保留编辑'), findsWidgets);
      expect(t.takeException(), isNull);
    },
  );
}
