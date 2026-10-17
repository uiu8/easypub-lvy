import 'dart:io';

import 'package:easypub_desktop/application/chapter_service.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/checks/checks_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'real check hub exposes later issue pages and invalidates after edits',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late PrototypeState backend;
      late LegacyLibraryAdapter library;
      late String id;
      await tester.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        final dir = (await Directory(
          '../artifacts',
        ).createTemp('check-hub-native-')).absolute;
        backend = PrototypeState(settingsDirectory: '${dir.path}/settings');
        library = LegacyLibraryAdapter(backend: backend);
        await library.load();
        await library.savePatch({'check_after_import': false});
        final source = File('${dir.path}/重复.txt')
          ..writeAsStringSync(
            List.generate(
              80,
              (i) => '第${i * 2 + 1}章 标题$i\n\n第$i处正文有不同内容。\n\n',
            ).join(),
          );
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        id = backend.currentId;
        final checks = library.openChecks(id);
        final report = await checks.inspect();
        expect(report.domains.first.failed, false);
        checks.dispose();
        final chapters = library.openChapters(id);
        final issues = await chapters.issues(
          await chapters.read(0),
          0,
          effective: true,
        );
        expect(issues.total, greaterThan(50));
        final filtered = chapters as FilteredChapterSession;
        final structure = await chapters.read(0);
        for (final mode in [true, false]) {
          final baseline = await chapters.issues(structure, 0, effective: mode);
          final all = <ChapterIssue>[...baseline.items];
          for (
            var offset = baseline.items.length;
            offset < baseline.total;
            offset += 50
          ) {
            all.addAll(
              (await chapters.issues(structure, offset, effective: mode)).items,
            );
          }
          expect(
            baseline.categoryCounts.values.fold<int>(0, (a, b) => a + b),
            baseline.total,
          );
          for (final category in baseline.categoryCounts.keys) {
            final expected = all.where((i) => i.category == category).toList();
            final page = await filtered.filteredIssues(
              structure,
              0,
              effective: mode,
              category: category,
            );
            expect(page.total, expected.length);
            expect(
              page.items.map((i) => i.id),
              expected.take(50).map((i) => i.id),
            );
            if (page.total > 50) {
              final second = await filtered.filteredIssues(
                structure,
                50,
                effective: mode,
                category: category,
              );
              expect(
                second.items.map((i) => i.id),
                expected.skip(50).take(50).map((i) => i.id),
              );
              expect(
                await chapters.issueSource(second, second.items.first),
                isNotEmpty,
              );
            }
          }
          for (final level in chapterIssueSeverities.keys) {
            final page = await filtered.filteredIssues(
              structure,
              0,
              effective: mode,
              severity: level,
            );
            expect(page.total, all.where((i) => i.severity == level).length);
          }
          final empty = await filtered.filteredIssues(
            structure,
            0,
            effective: mode,
            category: 'no-headings',
          );
          expect(empty.total, 0);
        }
      });
      addTearDown(() {
        library.dispose();
        backend.dispose();
      });
      var repaired = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: BookChecksPage(
                library: library,
                bookId: id,
                onRepair: (_) => repaired = true,
                onChapter: (_) {},
                onCatalog: () {},
                onCleanup: () {},
              ),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 120; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (i > 8 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            return;
          }
        }
        fail('check/context did not finish');
      }

      await settle();
      expect(find.byTooltip('对照方式'), findsOneWidget);
      expect(find.text('前章末尾'), findsOneWidget);
      expect(find.text('后章开头'), findsOneWidget);
      tester
          .widget<Slider>(find.byKey(const ValueKey('issue-position')))
          .onChangeEnd!(50);
      await settle();
      expect(find.textContaining('问题 51 /'), findsOneWidget);
      expect(find.byType(SelectionArea), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('check-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('未识别标题 (').last);
      await settle();
      expect(find.text('当前筛选没有匹配问题'), findsOneWidget);
      expect(find.byKey(const ValueKey('issue-position')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('check-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('编号跳跃 (').last);
      await settle();
      expect(find.byTooltip('对照方式'), findsOneWidget);
      expect(find.text('前章末尾'), findsOneWidget);
      expect(find.text('后章开头'), findsOneWidget);
      tester
          .widget<Slider>(find.byKey(const ValueKey('issue-position')))
          .onChangeEnd!(50);
      await settle();
      expect(find.textContaining('问题 51 /'), findsOneWidget);
      await tester.tap(find.text('完整方案'));
      expect(repaired, true);
      await tester.runAsync(() async {
        final chapter = library.openChapters(id);
        final tree = await chapter.read(0);
        await chapter.rename(tree, tree.nodes.first.id, '第一章 新标题');
      });
      await tester.pump();
      expect(find.text('需要重新检查'), findsOneWidget);
      expect(find.text('重新检查后显示当前问题'), findsOneWidget);
      expect(find.text('完整方案'), findsNothing);
      await tester.tap(find.text('检查本书'));
      await settle();
      expect(
        tester
            .widget<DeskChoice<String>>(
              find.byKey(const ValueKey('check-category')),
            )
            .value,
        'number-gap',
      );
      expect(find.textContaining('问题 51 /'), findsOneWidget);
      expect(find.byTooltip('对照方式'), findsOneWidget);
      expect(find.text('前章末尾'), findsOneWidget);
      expect(find.text('后章开头'), findsOneWidget);
      expect(find.text('需要重新检查'), findsNothing);
      await tester.runAsync(() async {
        final chapter = library.openChapters(id);
        await chapter.history(await chapter.read(0), undo: true);
      });
      await tester.pump();
      // A report matching the restored manuscript is reusable; rechecking it
      // must still preserve the user's issue filter and page.
      await tester.tap(find.text('检查本书'));
      await settle();
      expect(
        tester
            .widget<DeskChoice<String>>(
              find.byKey(const ValueKey('check-category')),
            )
            .value,
        'number-gap',
      );
      expect(find.textContaining('问题 51 /'), findsOneWidget);
      expect(find.byTooltip('对照方式'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
