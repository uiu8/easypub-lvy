import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/checks/batch_repair_dialog.dart';
import 'package:easypub_desktop/desk/checks/issue_browser.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets('检查页批量修复同类问题：勾选、合并预览、应用并复查（真实 Rust）', (t) async {
    t.view.physicalSize = const Size(1280, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    final original =
        '番外：生日\n原有番外正文\n${List.generate(30, (i) => '${238 + i}：标题$i\n正文$i 第一段\n第二段\n第三段\n').join()}';
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = (await Directory('../artifacts').createTemp('batch-repair-'))
          .absolute;
      state = PrototypeState(settingsDirectory: '${root.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({
        'check_after_import': false,
        'recognition_defaults': {
          ...await library.openRules(null).builtin(),
          'numeric_minimum_body_lines': 3,
        },
      });
      final source = File('${root.path}/数字章节.txt')..writeAsStringSync(original);
      expect((await library.importFiles([source.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final session = library.openChapters(state.currentId);
    Future<void> settle() async {
      for (var i = 0; i < 400; i++) {
        await t.pump(const Duration(milliseconds: 20));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        if (i > 10 &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          return;
        }
      }
      fail('batch repair did not settle');
    }

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: CheckIssueBrowser(
            session: session,
            enabled: true,
            onChapter: (_) {},
          ),
        ),
      ),
    );
    await settle();
    expect(find.byKey(const ValueKey('batch-repair')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('batch-repair')));
    await settle();
    expect(find.byType(BatchRepairDialog), findsOneWidget);
    expect(find.text('批量修复：漏识别的标题'), findsOneWidget);
    expect(find.text('预览 30 项修改'), findsOneWidget);
    // 取消第一项：只应用仍勾选的 29 项（V23 起第一个勾选框是表头全选，第一项是第二个）。
    await t.tap(
      find
          .descendant(
            of: find.byType(BatchRepairDialog),
            matching: find.byType(Checkbox),
          )
          .at(1),
    );
    await t.pump();
    expect(find.text('预览 29 项修改'), findsOneWidget);
    // 预览前书稿不变。
    await t.runAsync(() async => expect((await session.read(0)).total, 1));
    await t.tap(find.text('预览 29 项修改'));
    await settle();
    expect(find.text('应用 29 项修改'), findsOneWidget);
    // 影响统计由当前稿与候选稿各检查一次得到。
    expect(find.byKey(const ValueKey('repair-impact')), findsOneWidget);
    expect(find.text('1 → 30'), findsOneWidget);
    await t.runAsync(() async => expect((await session.read(0)).total, 1));
    await t.tap(find.text('应用 29 项修改'));
    await settle();
    expect(find.byType(BatchRepairDialog), findsNothing);
    await t.runAsync(() async {
      final tree = await (session as ChapterOutlineSession).readOutline();
      expect(tree.total, 30);
      // 未勾选的那一项仍是待处理的漏识别标题。
      final options = await (session as TargetedChapterRepairSession)
          .repairsForIssue(await session.read(0), 'unrecognized-heading:');
      expect(options.total, 1);
      expect(options.changes.single.line, 3);
    });
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
