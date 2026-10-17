import 'package:flutter/material.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/repair/repair_page.dart';

class _Library implements LibraryService {
  _Library(this.session);
  final _Session session;
  @override
  ChapterSession openChapters(String bookId) => session;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements ChapterSession {
  bool failConfirm = false, failRecheck = false;
  int confirms = 0, checks = 0;
  static const tree = ChapterPage([], 2, 0, 'revision');
  static const report = ChapterIssuePage([], 0, 0, effective: true);
  static const change = ChapterRepairChange(
    'finding',
    'node',
    '第一章 甲',
    2,
    1,
    '第一章 甲\n第一章 甲',
    '第一章 甲',
    false,
  );
  @override
  Future<ChapterPage> read(
    int offset, {
    bool includeBody = false,
    String? preferredNodeId,
  }) async => tree;
  @override
  Future<ChapterRepairOptions> repairs(ChapterPage page) async =>
      const ChapterRepairOptions(
        [change],
        1,
        ChapterIssuePage([], 1, 0, effective: true),
      );
  @override
  Future<ChapterRepairPlan> previewRepairs(
    ChapterRepairOptions options,
    Set<String> selectedIds,
  ) async => const ChapterRepairPlan(ChapterEditPreview(), [change]);
  @override
  Future<void> confirm(ChapterEditPreview preview) async {
    confirms++;
    if (failConfirm) {
      throw const FormatException('injected application rejection');
    }
  }

  @override
  Future<ChapterIssuePage> issues(
    ChapterPage page,
    int offset, {
    bool effective = false,
  }) async {
    checks++;
    if (failRecheck) throw const FormatException('injected recheck failure');
    return report;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final afterCommit in [false, true]) {
    testWidgets(
      afterCommit
          ? 'recheck failure retries without resubmitting'
          : 'application failure requires new preview and confirmation',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 960);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final captureDirectory = Platform.environment['EASYPUB_SCENE_CAPTURE'];
        final capture = GlobalKey();
        if (captureDirectory != null) {
          await tester.runAsync(() async {
            await (FontLoader('Microsoft YaHei')..addFont(
                  File('C:/Windows/Fonts/msyh.ttc')
                      .readAsBytes()
                      .then(ByteData.sublistView),
                ))
                .load();
            await (FontLoader('MaterialIcons')..addFont(
                  File(
                    'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
                  ).readAsBytes().then(ByteData.sublistView),
                ))
                .load();
            await Directory(captureDirectory).create(recursive: true);
          });
        }
        Future<void> shot(String name) async {
          if (captureDirectory == null) return;
          await tester.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('$captureDirectory/$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        final session = _Session()
          ..failConfirm = !afterCommit
          ..failRecheck = afterCommit;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: deskTheme(),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(24),
                  child: ChapterRepairPage(
                    library: _Library(session),
                    bookId: 'book',
                    onReturn: () {},
                    onEdit: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> tap(String text) async {
          await tester.tap(find.text(text));
          await tester.pumpAndSettle();
        }

        if (!afterCommit) await shot('repair-auto');
        await tap('查看完整差异');
        if (!afterCommit) await shot('repair-diff');
        await tap('确认应用并复查');
        expect(
          find.text(afterCommit ? '修复已应用，复查未完成' : '修复应用未完成'),
          findsOneWidget,
        );
        expect(find.text('确认应用并复查'), findsNothing);
        expect(session.confirms, 1);
        await shot(afterCommit ? 'repair-recheck-failed' : 'repair-failed');
        await tap('查看技术详情');
        expect(
          find.text(
            afterCommit
                ? 'injected recheck failure'
                : 'injected application rejection',
          ),
          findsOneWidget,
        );
        session.failConfirm = false;
        session.failRecheck = false;
        if (afterCommit) {
          await tap('重试复查');
          expect(session.confirms, 1);
          expect(session.checks, 2);
        } else {
          await tap('重新检测后重试');
          expect(session.confirms, 1);
          expect(find.text('确认应用并复查'), findsNothing);
          await tap('查看完整差异');
          await tap('确认应用并复查');
          expect(session.confirms, 2);
        }
        expect(find.text('已应用 1 项修复，并完成复查'), findsOneWidget);
        if (!afterCommit) await shot('repair-result');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
