// V2d 问题位置（CH-234–240）：真实 Rust 检查结果驱动目录刻度、计数与正文批注。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/chapters/chapter_view_state.dart';

Finder keyPrefix(String prefix) => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key as ValueKey<String>).value.startsWith(prefix),
);

void main() {
  testWidgets(
    'issue positions mark the outline, annotate the manuscript and open the issue in the browser',
    (t) async {
      t.view.physicalSize = const Size(1600, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late String id;
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        final root = (await Directory(
          '../artifacts',
        ).createTemp('issue-marks-')).absolute;
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        final source = File('${root.path}/跳号.txt')
          ..writeAsStringSync(
            List.generate(80, (i) => '第${i * 2 + 1}章 标题$i\n正文内容$i。\n\n').join(),
          );
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        id = state.currentId;
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      Future<void> settle() async {
        for (var i = 0; i < 300; i++) {
          await t.pump(const Duration(milliseconds: 20));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          if (i > 8 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty &&
              find.text('正在汇总问题…').evaluate().isEmpty) {
            return;
          }
        }
        fail('Chapter workspace did not settle');
      }

      // 汇总与分页报告必须一致：同一会话分别读取。
      final session = library.openChapters(id);
      late ChapterIssueMap map;
      late ChapterIssuePage report;
      await t.runAsync(() async {
        final page = await session.read(0);
        map = await (session as ChapterIssueMapSession).issueMap(page);
        report = await session.issues(page, 0, effective: true);
      });
      expect(map.total, report.total);
      expect(map.total, greaterThan(0));
      expect(map.open, map.total);
      expect(map.marks.values.fold<int>(0, (s, m) => s + m.count), map.total);

      final view = ChapterViewState();
      ChapterIssue? repaired;
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: ChapterWorkspace(
              library: library,
              bookId: id,
              viewState: view,
              onRepairIssue: (issue) => repaired = issue,
            ),
          ),
        ),
      );
      await settle();
      expect(t.takeException(), isNull);

      // CH-235/236：刻度条与底栏计数。
      expect(find.byKey(const ValueKey('chapter-issue-spine')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chapter-issue-counts')),
        findsOneWidget,
      );

      // CH-237：所选章节的批注。
      final notes = keyPrefix('chapter-issue-note-');
      expect(notes, findsWidgets);
      final noteId = (notes.evaluate().first.widget.key as ValueKey<String>)
          .value
          .substring('chapter-issue-note-'.length);

      // CH-240：收起后消失，展开后恢复，开关记在视图状态里。
      await t.tap(find.byKey(const ValueKey('chapter-issue-notes-toggle')));
      await t.pump();
      expect(notes, findsNothing);
      expect(view.showIssueNotes, false);
      await t.tap(find.byKey(const ValueKey('chapter-issue-notes-toggle')));
      await t.pump();
      expect(notes, findsWidgets);

      // CH-239：有修复候选时才出现“修复方案”，并转交逐项修复。
      final repair = keyPrefix('chapter-issue-repair-');
      if (repair.evaluate().isNotEmpty) {
        await t.tap(repair.first);
        await t.pump();
        expect(repaired, isNotNull);
      }

      // CH-235：点刻度选中对应章节。
      final before = view.nodeId;
      final spine = t.getRect(
        find.byKey(const ValueKey('chapter-issue-spine')),
      );
      final row = map.marks.values
          .where((m) => m.index != null && m.index! > 40)
          .map((m) => m.index!)
          .reduce((a, b) => a < b ? a : b);
      await t.tapAt(
        Offset(spine.center.dx, spine.top + (row + .5) / 80 * spine.height),
      );
      await settle();
      expect(view.nodeId, isNot(before));
      expect(map.marks.containsKey(view.nodeId), true);
      expect(notes, findsWidgets);

      // CH-238：“在问题中核对”切到问题页签并选中该问题。
      final review = keyPrefix('chapter-issue-review-');
      final reviewId = (review.evaluate().first.widget.key as ValueKey<String>)
          .value
          .substring('chapter-issue-review-'.length);
      await t.tap(review.first);
      await settle();
      // 浏览器载入后若没找到该问题，会改选本页第一项；仍等于它说明已翻到所在页并选中。
      expect(view.tab, 1);
      expect(view.issues.issueId, reviewId);
      expect(view.issues.category, isNull);
      expect(noteId, isNotEmpty);
      expect(t.takeException(), isNull);
    },
  );
}
