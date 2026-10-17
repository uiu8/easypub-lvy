import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_chapter_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/frontend_rewrite/features/chapters/chapters_page.dart';
import 'package:easypub_desktop/frontend_rewrite/features/chapters/continuous_chapter_tree.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class CountedChapters extends LegacyChapterSession {
  CountedChapters(super.backend, super.bookId);
  int reads = 0;
  @override
  Future<ChapterPage> read(
    int offset, {
    bool includeBody = false,
    String? preferredNodeId,
    bool fullOutline = false,
  }) {
    reads++;
    return super.read(
      offset,
      includeBody: includeBody,
      preferredNodeId: preferredNodeId,
      fullOutline: fullOutline,
    );
  }
}

class ScaleLibrary extends LegacyLibraryAdapter {
  ScaleLibrary(this.state) : super(backend: state);
  final PrototypeState state;
  final sessions = <String, CountedChapters>{};
  @override
  ChapterSession openChapters(String id) =>
      sessions.putIfAbsent(id, () => CountedChapters(state, id));
}

void main() {
  testWidgets(
    '10000 chapter UI reaches last chapter, searches, scrolls and edits without losing position',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late ScaleLibrary library;
      late File source;
      late String id, targetId, original;
      late int offset;
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        for (final font in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(font.key)..addFont(
                File(font.value)
                    .readAsBytes()
                    .then((b) => b.buffer.asByteData()),
              ))
              .load();
        }
        final root = (await Directory(
          '../artifacts',
        ).createTemp('chapter-ui68-')).absolute.path;
        state = PrototypeState(settingsDirectory: '$root/settings');
        library = ScaleLibrary(state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        original = List.generate(
          10000,
          (i) =>
              '${i % 100 == 0 ? '第${i ~/ 100 + 1}卷 卷名\n' : ''}第${i + 1}章 标题${i + 1}\n独立正文${i + 1}。\n',
        ).join();
        source = File('$root/万章.txt');
        await source.writeAsString(original);
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        id = library.books.value.single.id;
        final chapter = library.openChapters(id);
        offset = 10100 - 30;
        targetId = (await chapter.read(offset)).nodes.last.id;
        library.sessions[id]!.reads = 0;
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final capture = GlobalKey();
      final loading = Stopwatch()..start();
      await t.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            theme: deskTheme(),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: ChaptersPage(
                  library: library,
                  bookId: id,
                  initialNodeId: targetId,
                  initialOffset: offset,
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> waitFor(bool Function() ready) async {
        // Publish setState and allow native futures to run before testing idle.
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
        for (var i = 0; i < 500 && !ready(); i++) {
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
            find.text('10100 节点 · 已载入 10100').evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      final loadMs = loading.elapsedMilliseconds;
      expect(library.sessions[id]!.reads, lessThanOrEqualTo(3));
      expect(
        find.byKey(ValueKey('tree-node-$targetId')).hitTestable(),
        findsOneWidget,
      );
      expect(find.textContaining('独立正文10000'), findsWidgets);
      final tree = find.byType(ContinuousChapterTree);
      final search = find.descendant(
        of: tree,
        matching: find.byType(TextField),
      );
      final list = find.byKey(const ValueKey('continuous-chapter-list'));
      final scrollWatch = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        await t.drag(list, const Offset(0, 400));
        await t.pumpAndSettle();
      }
      final scrollMs = scrollWatch.elapsedMilliseconds;
      final beforeSearch = library.sessions[id]!.reads;
      await t.enterText(search, '第10000章');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(library.sessions[id]!.reads, beforeSearch);
      expect(find.text('1 个匹配 · 已检查 10100/10100 节点'), findsOneWidget);
      await t.tap(find.byKey(ValueKey('tree-node-$targetId')));
      await waitFor(
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      await t.tap(find.text('改名'));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('chapter-rename-input')),
        '第10000章 已修改',
      );
      await t.pump();
      await t.tap(find.text('预览并确认'));
      await waitFor(
        () =>
            find.text('确认写入草稿').evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      await t.tap(find.text('确认写入草稿'));
      await waitFor(
        () =>
            find.text('第10000章 已修改').evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find
                .byKey(ValueKey('tree-node-$targetId'))
                .hitTestable()
                .evaluate()
                .isNotEmpty,
      );
      expect(find.textContaining('独立正文10000'), findsWidgets);
      expect(
        find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key as ValueKey<String>).value.startsWith('tree-node-'),
            )
            .evaluate()
            .length,
        lessThan(50),
      );
      await t.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/chapter68-last.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        expect(await source.readAsString(), original);
      });
      expect(t.takeException(), isNull);
      stdout.writeln(
        'chapter68 UI load_ms=$loadMs scroll10_ms=$scrollMs reads=${library.sessions[id]!.reads} rss=${ProcessInfo.currentRss} peak_rss=${ProcessInfo.maxRss}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
