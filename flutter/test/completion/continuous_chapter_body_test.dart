import 'dart:ui';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/chapters/manuscript.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';

class BodySession extends Fake implements ChapterSession {
  final offsets = <int>[];
  @override
  Future<ChapterBody> body(ChapterPage page, String nodeId, int offset) async {
    offsets.add(offset);
    return ChapterBody(
      List.generate(
        (120 - offset).clamp(0, 30),
        (i) => '第${offset + i}段：连续阅读与跨块复制。',
      ),
      offset,
      120,
      offset + 30 < 120,
    );
  }
}

void main() {
  testWidgets(
    'native reader continues a long Unicode paragraph and copies it without truncation or injected newlines',
    (t) async {
      t.view.physicalSize = const Size(1100, 720);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final longLine = '${'长😀' * 1400}完整尾标';
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late ChapterSession session;
      late ChapterPage page;
      late ChapterBody first;
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        final dir = (await Directory(
          '../artifacts',
        ).createTemp('body-continuation-')).absolute;
        state = PrototypeState(settingsDirectory: '${dir.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        final file = File('${dir.path}/长段落.txt')
          ..writeAsStringSync('第一章 起\n$longLine\n续段仍在此章。\n第二章 末\n末章正文。\n');
        expect((await library.importFiles([file.path])).single.succeeded, true);
        session = library.openChapters(state.currentId);
        page = await session.read(0);
        first = await session.body(page, page.nodes.first.id, 0);
        expect(first.rows.first.nextCharOffset, 500);
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      var savedOffset = 0;
      var savedPixels = 0.0;
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: ChapterManuscript(
              session: session,
              page: page,
              node: page.nodes.first,
              initialBody: first,
              onPosition: (offset, pixels) {
                savedOffset = offset;
                savedPixels = pixels;
              },
            ),
          ),
        ),
      );
      Future<void> read() async {
        for (var i = 0; i < 20; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
        }
      }

      await read();
      for (var i = 0; i < 5 && find.text(longLine).evaluate().isEmpty; i++) {
        await t.drag(find.byType(CustomScrollView), const Offset(0, -1800));
        await read();
      }
      expect(find.text(longLine), findsOneWidget);
      expect(find.textContaining('本行预览已截断'), findsNothing);
      await t.ensureVisible(find.text('续段仍在此章。'));
      await t.pumpAndSettle();
      await t.tap(find.text('续段仍在此章。'));
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyA);
      await t.sendKeyEvent(LogicalKeyboardKey.keyC);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(copied, contains(longLine));
      expect(copied, contains('续段仍在此章。'));
      expect(copied, isNot(contains('末章正文。')));
      final controller = t
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      final targetPixels = (controller.position.maxScrollExtent * .7).clamp(
        1.0,
        600.0,
      );
      controller.jumpTo(targetPixels);
      await t.pumpAndSettle();
      expect(savedOffset, 0);
      final pixels = savedPixels;
      // 记忆的是视口顶相对首行顶的距离；首行上方有章节页眉，故不大于滚动量。
      expect(pixels, inInclusiveRange(0, targetPixels));
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: ChapterManuscript(
              session: session,
              page: page,
              node: page.nodes.first,
              initialBody: first,
              initialOffset: savedOffset,
              initialScroll: pixels,
            ),
          ),
        ),
      );
      await read();
      expect(
        t
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!
            .offset,
        closeTo(targetPixels, 2),
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'continuous reader loads adjacent blocks and copies across their boundary',
    (t) async {
      t.view.physicalSize = const Size(900, 680);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final session = BodySession();
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: ChapterManuscript(
              session: session,
              page: const ChapterPage([], 1, 0, 'one'),
              node: const ChapterNode('chapter', '第一章', 'chapter', 0, 1, true),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final first = find.text('第29段：连续阅读与跨块复制。');
      await t.ensureVisible(first);
      await t.pumpAndSettle();
      final next = find.text('第30段：连续阅读与跨块复制。');
      expect(session.offsets, contains(30));
      expect(next, findsOneWidget);
      final start = t.getRect(first), end = t.getRect(next);
      final gesture = await t.startGesture(
        Offset(start.left + 1, start.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(Offset(end.left + 300, end.center.dy));
      await gesture.up();
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyC);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(copied, contains('第29段'));
      expect(copied, contains('第30段'));
      expect(find.text('下段正文'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
}
