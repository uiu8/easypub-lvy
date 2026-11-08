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
import 'package:easypub_desktop/application/catalog_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_catalog_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_chapter_session.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/catalog/composition_dialog.dart';
import 'legacy_state_helpers.dart';

void main() {
  testWidgets(
    'catalog composition preserves manual edits and cleanup with real DLL',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = PrototypeState();
      addTearDown(state.dispose);
      final dir = Directory(
        '../artifacts/frontend-rewrite/catalog-composition-probe',
      );
      final source = File('${dir.path}/原稿.txt');
      const original = '第一章 甲\n正文  \n第二章 乙\n尾文  \n';
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
        for (final entry in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(entry.key)..addFont(
                File(entry.value)
                    .readAsBytes()
                    .then((b) => b.buffer.asByteData()),
              ))
              .load();
        }
        await state.importBookOutcome(source.absolute.path);
        final id = state.currentId;
        final s = state.current.source!;
        state.manuscript.manualEditDrafts[id] = {
          'source_id': s.sourceId,
          'source_revision': s.revision,
          'history': [
            [],
            [
              {'kind': 'rename_title', 'source_line': 3, 'title': '第二章 新乙'},
            ],
          ],
          'cursor': 1,
        };
        await state.cleanup.saveSettings(id, {
          'kind': 'cleanup',
          'pipeline': [
            {'kind': 'trim_trailing_spaces'},
          ],
        });
      });
      final session = LegacyCatalogSession(state, state.currentId);
      await tester.runAsync(() async {
        await expectLater(
          session.acquire('paste', '第一章 甲', declaredTotal: 0),
          throwsFormatException,
        );
        final candidate = await session.acquire(
          'paste',
          '第一卷 起\n第一章 甲\n第二章 乙',
          declaredTotal: 2,
        );
        expect(candidate.completeness, 'complete');
        session.accept(candidate);
      });
      final plan = (await tester.runAsync(
        () => session.preview(session.saved!, identityConfirmed: true),
      ))!;
      expect(plan.proposedEdits, greaterThan(0));
      final savedHistory = jsonEncode(state.manuscript.manualEditDrafts);
      final savedCleanup = jsonEncode(state.cleanup.drafts);
      await tester.runAsync(() async {
        final before = await session.composition(plan, 0, withCatalog: false);
        final after = await session.composition(plan, 0, withCatalog: true);
        expect(before.nodes.map((n) => n.title), ['第一章 甲', '第二章 新乙']);
        expect(after.nodes.map((n) => n.title), ['第一卷 起', '第一章 甲', '第二章 新乙']);
        expect(after.body!.lines, contains('正文'));
        expect(after.body!.lines, isNot(contains('正文  ')));
        final tail = await session.composition(
          plan,
          0,
          withCatalog: true,
          nodeId: after.nodes.last.id,
        );
        expect(tail.body!.lines, contains('尾文'));
      });
      CatalogRepairDraft? applied;
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  child: const Text('打开组合预览'),
                  onPressed: () async {
                    applied = await showDialog<CatalogRepairDraft>(
                      context: context,
                      builder: (_) => CatalogCompositionDialog(
                        session: session,
                        alignment: plan,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump();
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
            await tester.pumpAndSettle();
            return;
          }
        }
        fail('composition did not finish');
      }

      await tester.tap(find.text('打开组合预览'));
      await settle();
      expect(find.text('第一卷 起'), findsOneWidget);
      expect(find.text('第二章 新乙'), findsOneWidget);
      expect(find.text('正文'), findsOneWidget);
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/composition.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('当前有效草稿'));
      await settle();
      expect(find.text('第一卷 起'), findsNothing);
      expect(find.text('第二章 新乙'), findsOneWidget);
      expect(jsonEncode(state.manuscript.manualEditDrafts), savedHistory);
      expect(jsonEncode(state.cleanup.drafts), savedCleanup);
      await tester.tap(find.text('加入目录方案后'));
      await settle();
      await tester.tap(find.text('已核对组合结果，应用到可撤销草稿'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认应用目录修复'));
      await settle();
      expect(applied, isNotNull);
      expect(find.text('目录修复 · 组合预览'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        final chapters = LegacyChapterSession(state, state.currentId);
        var tree = await chapters.read(0);
        expect(tree.nodes.map((n) => n.title), ['第一卷 起', '第一章 甲', '第二章 新乙']);
        final project =
            '${dir.absolute.path}/应用目录-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
        expect(
          await state.saveProjectOutcome(project),
          true,
          reason: state.projectStatus,
        );
        final restored = PrototypeState();
        try {
          await restored.openProjectOutcome(project);
          final reopened = LegacyChapterSession(restored, restored.currentId);
          final result = await reopened.read(0);
          expect(
            result.nodes.map((n) => n.title),
            tree.nodes.map((n) => n.title),
          );
          final base = restored.manuscript.effectiveBase(restored.currentId);
          final selected = jsonEncode({
            'kind': 'publication',
            'manual': base['manual'],
            'cleanup': base['cleanup'],
            'post_edits': restored.manuscript.effectiveSelection(restored.currentId),
          });
          final src = restored.current.source!;
          final outputPlan = jsonDecode(
            await api.previewRepairPlanText(
              sourceId: src.sourceId,
              revision: src.revision,
              selectedJson: selected,
            ),
          ) as Map;
          final output = File(
            '${dir.absolute.path}/目录修订-${DateTime.now().microsecondsSinceEpoch}.txt',
          );
          final receipt = jsonDecode(
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
          expect(receipt['committed'], true);
          expect(await output.readAsString(), '第一卷 起\n第一章 甲\n正文\n第二章 新乙\n尾文\n');
          await reopened.history(result, undo: true);
          expect((await reopened.read(0)).nodes.map((n) => n.title), [
            '第一章 甲',
            '第二章 新乙',
          ]);
        } finally {
          restored.dispose();
        }
        await applied!.session.undoConfirmed(applied!.preview);
        tree = await chapters.read(0);
        expect(tree.nodes.map((n) => n.title), ['第一章 甲', '第二章 新乙']);
        await chapters.rename(tree, tree.nodes.first.id, '第一章 人工改名');
        await expectLater(
          session.composition(plan, 0, withCatalog: true),
          throwsFormatException,
        );
        final fresh = await session.preview(
          session.saved!,
          identityConfirmed: true,
        );
        final candidate = await session.prepareRepair(fresh);
        final proposed = await candidate.session.previewTree(
          candidate.preview,
          0,
        );
        expect(proposed.nodes.map((n) => n.title), [
          '第一卷 起',
          '第一章 人工改名',
          '第二章 新乙',
        ]);
        session.cancel();
        await expectLater(
          candidate.session.confirm(candidate.preview),
          throwsFormatException,
        );
        final intact = await chapters.read(0);
        expect(intact.nodes.first.title, '第一章 人工改名');
        expect(await source.readAsString(), original);
      });
      expect(tester.takeException(), isNull);
    },
  );
}
