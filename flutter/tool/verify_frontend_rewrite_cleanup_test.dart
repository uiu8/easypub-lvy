import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';

class _Picker implements BookFilePicker {
  @override
  Future<List<String>> chooseBooks() async => [];
  @override
  Future<String?> chooseFolder() async => null;
  @override
  Future<String?> chooseProject() async => null;
  @override
  Future<String?> chooseProjectDestination() async => null;
}

void main() {
  testWidgets(
    'new cleanup preview is read-only, adoption survives project, stale and cancelled plans reject',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      final dir = Directory('../artifacts/frontend-rewrite/cleanup-probe');
      final source = File('${dir.path}/长河照影.txt');
      const original = '第一章 夜渡\n夜色落在河面上  \n\n\n请收藏\n第二章 来信\n他走到岸边。\n';
      final backend = PrototypeState();
      addTearDown(backend.dispose);
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
        for (final e in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(e.key)..addFont(
                File(e.value).readAsBytes().then((v) => v.buffer.asByteData()),
              ))
              .load();
        }
        await backend.importBookOutcome(source.absolute.path);
      });
      final library = LegacyLibraryAdapter(backend: backend);
      addTearDown(library.dispose);
      final id = backend.currentId,
          session = library.openCleanup(backend.currentId);
      addTearDown(session.dispose);
      await tester.runAsync(() async {
        final draft = jsonDecode(session.settings) as Map<String, dynamic>;
        final rules = draft['pipeline'] as List;
        final first = rules.first as Map;
        rules[0] = first['kind'] == 'configured'
            ? {...first, 'name': '正文空白整理'}
            : {
                'kind': 'configured',
                'enabled': true,
                'scope': 'all',
                'name': '正文空白整理',
                'rule': first,
              };
        rules.add({'kind': 'remove_ad_lines'});
        final plan = await session.preview(jsonEncode(draft));
        expect(plan.total, 2);
        final beforeCheck = await session.recheck();
        expect(beforeCheck.changes, 2);
        expect(beforeCheck.candidates, 1);
        expect(plan.candidateTotal, 1);
        expect(plan.candidates.single.text, '请收藏');
        expect(plan.candidates.single.selectable, true);
        expect(backend.cleanup.drafts.containsKey(id), false);
        session.cancel();
        await expectLater(session.apply(plan), throwsFormatException);
        // A source-bound exclusion preserves only this step and source range.
        final keptDraft = {
          ...draft,
          'step_exclusions': [
            {'step_index': 0, 'source_line': 2, 'source_end_line': 2},
          ],
        };
        final kept = await session.preview(jsonEncode(keptDraft));
        expect(kept.total, 1);
        expect(kept.actions.any((v) => v.line == 2), false);
        final selectedDraft = {
          ...draft,
          'remove_lines': [5],
        };
        final selectedPlan = await session.preview(jsonEncode(selectedDraft));
        expect(selectedPlan.total, 3);
        expect(selectedPlan.candidates.single.selected, true);
        expect(
          selectedPlan.actions.any((v) => v.line == 5 && v.after == null),
          true,
        );
        expect(backend.cleanup.drafts.containsKey(id), false);
        final current = await session.preview(jsonEncode(draft));
        final receipt = await session.apply(current);
        expect(receipt.changes, 2);
        final afterCheck = await session.recheck();
        expect(afterCheck.changes, 0);
        expect(afterCheck.candidates, 1);
        expect(afterCheck.compositionId, isNot(beforeCheck.compositionId));
        expect(session.isInspectionCurrent(beforeCheck), false);
        expect(session.isInspectionCurrent(afterCheck), true);
        final candidate = afterCheck.findings.single;
        expect(candidate.line, 4);
        expect(candidate.originalLine, 5);
        expect(
          await session.inspectionSource(afterCheck, candidate),
          contains('请收藏'),
        );
        final beforeRemoval = jsonEncode(backend.cleanup.drafts);
        final removal = await session.previewInspectionRemoval(
          afterCheck,
          candidate,
        );
        expect(removal.total, 3);
        expect(jsonDecode(removal.request)['remove_lines'], contains(5));
        expect(jsonEncode(backend.cleanup.drafts), beforeRemoval);
        await session.apply(removal);
        expect((await session.recheck()).candidates, 0);
        await expectLater(
          session.inspectionSource(afterCheck, candidate),
          throwsFormatException,
        );
        await session.undo();
        final keptSettings =
            jsonDecode(session.settings) as Map<String, dynamic>;
        keptSettings['skip_lines'] = [5];
        await session.apply(await session.preview(jsonEncode(keptSettings)));
        final keptInspection = await session.recheck();
        final unchanged = jsonEncode(backend.cleanup.drafts);
        await expectLater(
          session.previewInspectionRemoval(
            keptInspection,
            keptInspection.findings.single,
          ),
          throwsFormatException,
        );
        expect(jsonEncode(backend.cleanup.drafts), unchanged);
        await session.undo();
        expect(backend.cleanup.drafts[id]!['remove_lines'] ?? [], isEmpty);
        expect(session.canUndo, true);
        final project =
            '${dir.absolute.path}/project-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
        expect((await library.saveProject(project)).succeeded, true);
        await session.undo();
        expect(backend.cleanup.drafts.containsKey(id), false);
        expect(session.isInspectionCurrent(afterCheck), false);
        expect((await session.recheck()).changes, 2);
        expect((await library.openProject(project)).succeeded, true);
        expect(
          (backend.cleanup.drafts[id]!['pipeline'] as List).first['name'],
          '正文空白整理',
        );
        expect(backend.cleanup.drafts[id], isNotNull);
        await session.undo();
        expect(backend.cleanup.drafts.containsKey(id), false);
        await session.redo();
        expect(backend.cleanup.drafts[id], isNotNull);
        final selected = jsonEncode({
          'kind': 'publication',
          'cleanup': backend.cleanup.drafts[id],
        });
        final src = backend.current.source!;
        final outputPlan = jsonDecode(
          await api.previewRepairPlanText(
            sourceId: src.sourceId,
            revision: src.revision,
            selectedJson: selected,
          ),
        ) as Map;
        final output = File(
          '${dir.absolute.path}/清理修订-${DateTime.now().microsecondsSinceEpoch}.txt',
        );
        final savedOutput = jsonDecode(
          await api.commitRepairOutputText(
            sourceId: src.sourceId,
            revision: src.revision,
            sourcePath: source.absolute.path,
            outputPath: output.path,
            selectedJson: selected,
            planId: outputPlan['plan_id'],
            confirmed: true,
          ),
        ) as Map;
        expect(savedOutput['committed'], true);
        expect(
          await output.readAsString(),
          '第一章 夜渡\n夜色落在河面上\n\n请收藏\n第二章 来信\n他走到岸边。\n',
        );
        final stale = await session.preview(session.settings);
        final chapters = library.openChapters(id),
            tree = await library.openChapters(id).read(0);
        await chapters.rename(tree, tree.nodes.last.id, '第二章 新来信');
        expect(session.isCurrent(stale), false);
        await expectLater(session.apply(stale), throwsFormatException);
        final beforeConflict = jsonEncode(backend.cleanup.drafts);
        await expectLater(
          session.preview(jsonEncode(keptDraft)),
          throwsA(isA<api.ApiError>()),
        );
        expect(jsonEncode(backend.cleanup.drafts), beforeConflict);
        final pending = session.preview(session.settings);
        session.cancel();
        await expectLater(pending, throwsFormatException);
        await chapters.history(await chapters.read(0), undo: true);
        await session.undo();
        expect(await source.readAsString(), original);
      });
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: RewriteApp(library: library, picker: _Picker()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('文本清理').first);
      for (var i = 0; i < 300; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (i > 10 && find.byType(LinearProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('有序规则'), findsOneWidget);
      Future<void> settle() async {
        await tester.pump();
        for (var i = 0; i < 300; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          if (i > 10 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty) {
            await tester.pumpAndSettle();
            return;
          }
        }
        fail('cleanup operation timed out');
      }

      Future<void> shot(String name) async => tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('自动检测'));
      await settle();
      expect(find.textContaining('2 处变更'), findsOneWidget);
      expect(backend.cleanup.drafts.containsKey(id), false);
      await tester.tap(find.text('编辑规则'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('试算本书'));
      await tester.tap(find.text('试算本书'));
      await settle();
      expect(find.text('整套规则：2 处变更 · 1 条提示候选'), findsOneWidget);
      await tester.ensureVisible(find.text('取消'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      // Cancelling the isolated probe must leave the page's old preview usable.
      await tester.tap(find.text('查看清理差异'));
      await tester.pumpAndSettle();
      expect(find.text('确认采用清理方案'), findsOneWidget);
      expect(backend.cleanup.drafts.containsKey(id), false);
      expect(find.text('隐藏空白标记'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.textContaining('夜色落在河面上··'), findsOneWidget);
      await tester.tap(find.text('隐藏空白标记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('范围：全部源行'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (v) => v is TextField && v.decoration?.labelText == '起始源行',
        ),
        '2',
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (v) => v is TextField && v.decoration?.labelText == '结束源行',
        ),
        '2',
      );
      await tester.tap(find.text('使用此范围'));
      await tester.pumpAndSettle();
      expect(find.text('源行 2–2'), findsOneWidget);
      await tester.tap(find.text('自动检测'));
      await settle();
      expect(find.textContaining('检测完成 · 1 处变更'), findsOneWidget);
      await tester.tap(find.text('撤销').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('自动检测'));
      await settle();
      await tester.tap(find.text('保留原文'));
      await settle();
      await tester.tap(find.text('自动检测'));
      await settle();
      expect(find.textContaining('检测完成 · 1 处变更'), findsOneWidget);
      await tester.tap(find.text('撤销').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('自动检测'));
      await settle();
      expect(find.textContaining('2 处变更'), findsOneWidget);
      await shot('cleanup');
      await tester.tap(find.text('查看清理差异'));
      await tester.pumpAndSettle();
      await shot('cleanup-diff');
      await tester.tap(find.text('确认采用清理方案'));
      await settle();
      expect(find.text('已采用 2 处清理'), findsOneWidget);
      await tester.tap(find.text('复查当前有效稿'));
      await settle();
      expect(find.text('有效稿基础复查：0 处空白变更 · 1 条广告候选。'), findsOneWidget);
      await shot('cleanup-result');
      await tester.tap(find.text('定位复查问题'));
      await settle();
      await tester.tap(find.textContaining('广告与页眉候选 · 有效稿第'));
      await settle();
      expect(find.text('原稿第 5 行'), findsOneWidget);
      await tester.tap(find.text('刷新原稿上下文'));
      await settle();
      await shot('cleanup-inspection');
      await tester.tap(find.text('预览排除此候选'));
      await settle();
      expect(find.text('确认采用清理方案'), findsOneWidget);
      expect(backend.cleanup.drafts[id]!['remove_lines'] ?? [], isEmpty);
      await tester.tap(find.text('确认采用清理方案'));
      await settle();
      await tester.tap(find.text('复查当前有效稿'));
      await settle();
      expect(find.text('有效稿基础复查：0 处空白变更 · 0 条广告候选。'), findsOneWidget);
      expect(backend.cleanup.drafts.containsKey(id), true);
      await tester.tap(find.text('撤销本次清理'));
      await settle();
      await tester.tap(find.text('撤销').first);
      await settle();
      expect(backend.cleanup.drafts.containsKey(id), false);
      await tester.tap(find.text('添加规则'));
      await tester.pumpAndSettle();
      expect(find.text('编辑清理规则'), findsOneWidget);
      await tester.ensureVisible(find.text('试算本书'));
      await tester.tap(find.text('试算本书'));
      await settle();
      expect(find.text('整套规则：2 处变更 · 1 条提示候选'), findsOneWidget);
      expect(find.textContaining('原文  "夜色落在河面上  "'), findsOneWidget);
      expect(backend.cleanup.drafts.containsKey(id), false);
      await shot('cleanup-rule');
      await tester.ensureVisible(find.text('保存待检测规则'));
      await tester.tap(find.text('保存待检测规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本书检查'));
      await tester.pumpAndSettle();
      expect(find.text('离开文本清理？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('有序规则'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () async => expect(await source.readAsString(), original),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
