import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/cleanup_service.dart';
import 'package:easypub_desktop/desk/cleanup/paired_context.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'real cleanup paired regions show merges deletions and reject stale contexts',
    (t) async {
      t.view.physicalSize = const Size(1000, 750);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late CleanupSession session;
      late CleanupPreview plan;
      late CleanupChange change;
      late File source;
      const original = '第一章 起\n长长中文段落\n继续中文尾句。\n\n\n末段。\n';
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        final root = (await Directory(
          '../artifacts',
        ).createTemp('cleanup-context72-')).absolute;
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
              {'kind': 'join_hard_wraps', 'mode': 'chinese', 'min_chars': 4},
              {'kind': 'collapse_blank_lines'},
            ],
          }),
        );
        change = plan.actions.firstWhere((c) => c.line == 2);
        final paired = await (session as PairedCleanupContextSession)
            .pairedContext(plan, change);
        expect(paired['plan_id'], plan.id);
        final rows = (paired['rows'] as List).cast<Map>();
        final merged = rows.firstWhere((r) => r['source_line'] == 2);
        expect(merged['source_end_line'], 3);
        expect(merged['output_line'], 2);
        expect(merged['after'], '长长中文段落继续中文尾句。\n');
        expect(rows.any((r) => r['after'] == null), true);
        expect(source.readAsStringSync(), original);
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
        fail('Paired context did not load');
      }

      Widget view(Key key) => MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: CleanupPairedContext(
              key: key,
              session: session as PairedCleanupContextSession,
              preview: plan,
              change: change,
              showWhitespace: true,
            ),
          ),
        ),
      );
      await t.pumpWidget(view(const ValueKey('current')));
      await settle();
      expect(find.textContaining('· 合并'), findsOneWidget);
      expect(find.text('（已删除）'), findsOneWidget);
      expect(find.text('（空行）'), findsWidgets);
      final originalCell = t.getTopLeft(find.text('原稿 2—3 行'));
      final resultCell = t.getTopLeft(find.text('清理后 2—2 行 · 合并'));
      expect(originalCell.dy, resultCell.dy);
      expect(originalCell.dx, lessThan(resultCell.dx));
      await t.runAsync(() async {
        await session.apply(plan);
        await expectLater(
          (session as PairedCleanupContextSession).pairedContext(plan, change),
          throwsA(isA<FormatException>()),
        );
        expect(source.readAsStringSync(), original);
      });
      await t.pumpWidget(view(const ValueKey('stale')));
      await settle();
      expect(find.text('对照不可用'), findsOneWidget);
      expect(find.text('（已删除）'), findsNothing);
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );
}
