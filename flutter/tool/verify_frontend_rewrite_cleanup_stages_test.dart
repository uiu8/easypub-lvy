import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/cleanup/cleanup_page.dart';
import 'legacy_state_helpers.dart';

void main() {
  testWidgets(
    'ordered stages page independently and preserving a step differs from preserving source',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = PrototypeState();
      addTearDown(backend.dispose);
      final dir = Directory(
        '../artifacts/frontend-rewrite/cleanup-stages-probe',
      );
      final source = File('${dir.path}/有序规则.txt');
      final original = '第一章 开始\n${List.filled(46, '甲文  \n').join()}请收藏\n';
      final request = {
        'kind': 'cleanup',
        'pipeline': [
          {'kind': 'trim_trailing_spaces'},
          {'kind': 'literal_replace', 'find': '甲文', 'replace': '乙文'},
          {'kind': 'remove_ad_lines'},
        ],
      };
      await tester.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            File(
              Platform.environment['EASYPUB_TEST_DLL'] ??
                  '../target/release/easypub_bridge.dll',
            ).absolute.path,
          ),
        );
        await dir.create(recursive: true);
        await source.writeAsString(original);
        await backend.importBookOutcome(source.absolute.path);
        await backend.cleanup.saveSettings(backend.currentId, request);
      });
      final library = LegacyLibraryAdapter(backend: backend);
      addTearDown(library.dispose);
      final session = library.openCleanup(backend.currentId);
      addTearDown(session.dispose);
      await tester.runAsync(() async {
        final first = await session.preview(session.settings);
        expect(first.total, 46);
        expect(first.stageTotal, 92);
        expect(first.actions.length, 40);
        expect(first.stages.length, 40);
        expect(first.actions.first.before, '甲文  ');
        expect(first.actions.first.after, '乙文');
        expect(first.stages.first.before, '甲文  ');
        expect(first.stages.first.after, '甲文');
        final middle = await session.preview(session.settings, offset: 40);
        expect(middle.actions.length, 6);
        expect(middle.stages.length, 40);
        expect(middle.stages.where((v) => v.step == 0).length, 6);
        expect(middle.stages.where((v) => v.step == 1).length, 34);
        final end = await session.preview(session.settings, offset: 80);
        expect(end.actions, isEmpty);
        expect(end.stages.length, 12);
        expect(
          end.stages.every((v) => v.before == '甲文' && v.after == '乙文'),
          true,
        );
        await expectLater(session.apply(first), throwsFormatException);
        final stepKept = await session.preview(
          jsonEncode({
            ...request,
            'step_exclusions': [
              {'step_index': 0, 'source_line': 2, 'source_end_line': 2},
            ],
          }),
        );
        expect(stepKept.stageTotal, 91);
        expect(stepKept.actions.first.after, '乙文  ');
        final sourceKept = await session.preview(
          jsonEncode({
            ...request,
            'skip_lines': [2],
          }),
        );
        expect(sourceKept.total, 45);
        expect(sourceKept.stageTotal, 90);
        expect(sourceKept.actions.any((v) => v.line == 2), false);
      });
      final before = jsonEncode(backend.cleanup.drafts);
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: CleanupPage(
                library: library,
                bookId: backend.currentId,
                navigation: CleanupNavigationGuard(),
                onChecks: () {},
              ),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        await tester.pump();
        for (var i = 0; i < 300; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
            await tester.pumpAndSettle();
            return;
          }
        }
        fail('cleanup did not finish');
      }

      await tester.tap(find.text('自动检测'));
      await settle();
      await tester.tap(find.text('最终差异').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('逐步骤差异').last);
      await tester.pumpAndSettle();
      expect(find.text('92 条步骤记录'), findsOneWidget);
      expect(find.text('步骤前 · 对应原稿 · 第 2–2 行'), findsOneWidget);
      await tester.tap(find.text('查看完整步骤'));
      await settle();
      expect(find.text('规则 1 · 完整步骤对照'), findsOneWidget);
      expect(find.byKey(const ValueKey('cleanup-region-before')), findsOneWidget);
      expect(find.byKey(const ValueKey('cleanup-region-after')), findsOneWidget);
      await tester.tap(find.byTooltip('关闭完整对照'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 40; i++) {
        await tester.tap(find.text('下一处'));
        await settle();
      }
      expect(find.text('41 / 92 · 规则 1'), findsOneWidget);
      expect(find.text('步骤前 · 对应原稿 · 第 42–42 行'), findsOneWidget);
      await tester.tap(find.text('审阅提示候选'));
      await settle();
      expect(find.text('请收藏'), findsOneWidget);
      expect(find.text('提示候选 1–1 / 1'), findsOneWidget);
      await tester.tap(find.text('查看变更'));
      await settle();
      expect(find.text('步骤前 · 对应原稿 · 第 2–2 行'), findsOneWidget);
      await tester.tap(find.text('逐步骤差异').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('最终差异').last);
      await settle();
      expect(find.text('原稿 2—2 行'), findsOneWidget);
      await tester.tap(find.text('最终差异').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('逐步骤差异').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留本步原文'));
      await settle();
      await tester.tap(find.text('自动检测'));
      await settle();
      expect(find.text('91 条步骤记录'), findsOneWidget);
      await tester.tap(find.text('逐步骤差异').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('最终差异').last);
      await settle();
      expect(find.textContaining('乙文··'), findsOneWidget);
      await tester.tap(find.text('保留原文'));
      await settle();
      await tester.tap(find.text('自动检测'));
      await settle();
      expect(find.textContaining('检测完成 · 45 处变更'), findsOneWidget);
      expect(find.text('原稿 3—3 行'), findsOneWidget);
      expect(jsonEncode(backend.cleanup.drafts), before);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () async => expect(await source.readAsString(), original),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
