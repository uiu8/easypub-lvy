import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/cleanup_service.dart';
import 'package:easypub_desktop/desk/cleanup/region_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'intermediate step browses full Unicode content and rejects stale plan',
    (t) async {
      t.view.physicalSize = const Size(1200, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late CleanupSession session;
      late CleanupPreview plan;
      late File source;
      final original = '${'😀汉' * 2100}尾声\r\n';
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        final root = (await Directory(
          '../artifacts',
        ).createTemp('cleanup-step74-')).absolute;
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        source = File('${root.path}/样书.txt')..writeAsStringSync(original);
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        session = library.openCleanup(state.currentId);
        plan = await session.preview(
          jsonEncode({
            'kind': 'cleanup',
            'pipeline': [
              {'kind': 'literal_replace', 'find': '汉', 'replace': '乙'},
              {'kind': 'literal_replace', 'find': '乙', 'replace': ''},
              {'kind': 'literal_replace', 'find': '尾声', 'replace': '终章'},
            ],
          }),
        );
      });
      addTearDown(() {
        session.dispose();
        library.dispose();
        state.dispose();
      });
      Future<void> settle() async {
        for (var i = 0; i < 300; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
        }
        fail('Region did not load');
      }

      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: CleanupRegionDialog(
              session: session as PairedCleanupContextSession,
              preview: plan,
              change: plan.stages.firstWhere((c) => c.step == 1),
              regionLine: 1,
              stage: true,
              showWhitespace: false,
            ),
          ),
        ),
      );
      await settle();
      String side(String key) => t
          .widget<SelectableText>(find.byKey(ValueKey('cleanup-region-$key')))
          .data!;
      expect(side('before'), '😀乙' * 1000);
      expect(side('after'), '😀' * 2000);
      await t.tap(find.text('后一段'));
      await t.pump();
      await settle();
      expect(side('before'), '😀乙' * 1000);
      expect(side('after'), '${'😀' * 100}尾声');
      await t.tap(find.text('后一段'));
      await t.pump();
      await settle();
      expect(side('before'), '${'😀乙' * 100}尾声');
      expect(side('after'), '（本侧已结束）');
      expect(find.text('步骤后 · 已读完，共 2102 字符'), findsOneWidget);
      await t.tap(find.text('前一段'));
      await t.pump();
      await settle();
      expect(side('after'), '${'😀' * 100}尾声');
      await t.runAsync(() => session.apply(plan));
      await t.tap(find.text('前一段'));
      await t.pump();
      await settle();
      expect(find.text('对照不可用'), findsOneWidget);
      expect(find.byKey(const ValueKey('cleanup-region-before')), findsNothing);
      expect(source.readAsStringSync(), original);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
