import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/cleanup_service.dart';
import 'package:easypub_desktop/desk/cleanup/batch_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/rules/rules_sheet.dart';

/// V17：撤销 / 重做清理时换算章节修改（CLEAN-103）；检查点之上的修改也能换算（CLEAN-105）。
/// 真实 Rust。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  // 第一章“甲文”行尾有两个空格，第 3、4 行是连续空行。
  const blanks = '第一章 开始\n甲文  \n\n\n乙文\n第二章 后续\n丙文\n';
  const pipeline = {
    'kind': 'cleanup',
    'pipeline': [
      {'kind': 'trim_trailing_spaces'},
      {'kind': 'collapse_blank_lines'},
    ],
  };

  Future<(PrototypeState, LegacyLibraryAdapter, List<String>)> open(
    String prefix,
    int count,
  ) async {
    final root = (await Directory('../artifacts').createTemp(prefix)).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    await library.load();
    await library.savePatch({'check_after_import': false});
    for (var i = 0; i < count; i++) {
      final file = File('${root.path}/书$i.txt')..writeAsStringSync(blanks);
      expect((await library.importFiles([file.path])).single.succeeded, true);
    }
    return (state, library, library.books.value.map((b) => b.id).toList());
  }

  Future<void> applyCleanup(LegacyLibraryAdapter library, String id) async {
    final cleanup = library.openCleanup(id);
    try {
      final plan = await cleanup.preview(jsonEncode(pipeline));
      final impact = await cleanup.impact(plan);
      expect(impact.skipped, isEmpty);
      expect(impact.checkpoint, false);
      await cleanup.apply(plan);
    } finally {
      cleanup.dispose();
    }
  }

  Future<String> firstTitle(LegacyLibraryAdapter library, String id) async {
    final chapters = library.openChapters(id);
    return (await chapters.read(0)).nodes.first.title;
  }

  Future<List<String>> firstBody(
    LegacyLibraryAdapter library,
    String id,
  ) async {
    final chapters = library.openChapters(id);
    final page = await chapters.read(0);
    return (await chapters.body(page, page.nodes.first.id, 0)).lines;
  }

  test('撤销与重做清理：章节修改换算保留；无法换算的列出，确认后才放弃（CLEAN-103）', () async {
    final (state, library, ids) = await open('v17-undo-', 2);
    try {
      // 1) 只有改名：撤销、重做清理都直接完成，改名保留。
      final chapters = library.openChapters(ids[0]);
      final page = await chapters.read(0);
      await chapters.rename(page, page.nodes.first.id, '第一章 改名');
      await applyCleanup(library, ids[0]);
      final cleanup = library.openCleanup(ids[0]);
      try {
        await cleanup.undo();
        expect(state.cleanup.drafts[ids[0]], isNull);
        expect(await firstTitle(library, ids[0]), '第一章 改名');
        expect((await firstBody(library, ids[0])).first, '甲文  ');
        expect(state.cleanup.historyStatus[ids[0]], contains('1 处章节修改已换算'));
        await cleanup.redo();
        expect(state.cleanup.drafts[ids[0]], isNotNull);
        expect(await firstTitle(library, ids[0]), '第一章 改名');
        expect((await firstBody(library, ids[0])).first, '甲文');
      } finally {
        cleanup.dispose();
      }

      // 2) 先采用再撤销清理（没有章节修改），然后改名并删除第 4 行的空行
      //    （章内第 3 行，标题为第 0 行）。重做清理会合并连续空行，这一行不再存在：
      //    删除无法换算，需要确认；确认前状态不变。
      await applyCleanup(library, ids[1]);
      final back = library.openCleanup(ids[1]);
      try {
        await back.undo();
      } finally {
        back.dispose();
      }
      expect(state.cleanup.drafts[ids[1]], isNull);
      final second = library.openChapters(ids[1]);
      final plain = await second.read(0);
      await second.rename(plain, plain.nodes.first.id, '第一章 改名');
      final renamed = await second.read(0);
      await second.confirm(
        await second.preview(
          renamed,
          ExcludeChapterBodyLines(renamed.nodes.first.id, 3, 3),
        ),
      );
      final drafts = jsonEncode(state.cleanup.drafts);
      final edits = jsonEncode(state.manuscript.effectiveHistories[ids[1]]);
      final conflict = library.openCleanup(ids[1]);
      try {
        CleanupEditsNeedConfirmation? request;
        try {
          await conflict.redo();
        } on CleanupEditsNeedConfirmation catch (e) {
          request = e;
        }
        expect(request, isNotNull);
        expect(request!.redo, true);
        expect(request.kept, 1);
        expect(request.skipped.length, 1);
        expect(request.skipped.single.action, '删除正文行');
        expect(request.skipped.single.reason, '对应的行被清理删除或改动');
        expect(jsonEncode(state.cleanup.drafts), drafts);
        expect(jsonEncode(state.manuscript.effectiveHistories[ids[1]]), edits);
        await request.proceed();
        expect(state.cleanup.drafts[ids[1]], isNotNull);
        expect(await firstTitle(library, ids[1]), '第一章 改名');
        expect((await firstBody(library, ids[1])).first, '甲文');
        // 确认后再改了历史，旧的确认不能再套用。
        await expectLater(request.proceed(), throwsFormatException);
      } finally {
        conflict.dispose();
      }
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  test('章节修改压缩为检查点后，采用、撤销清理仍能换算（CLEAN-105）', () async {
    final (state, library, ids) = await open('v17-checkpoint-', 1);
    final id = ids.single;
    try {
      final chapters = library.openChapters(id);
      final page = await chapters.read(0);
      await chapters.rename(page, page.nodes.first.id, '第一章 压缩前');
      await chapters.confirm(
        await (chapters as ChapterCheckpointSession).previewCheckpoint(
          await chapters.read(0),
        ),
      );
      expect(state.manuscript.effectiveSelection(id)!['checkpoint'], isNotNull);
      expect(state.manuscript.effectiveCheckpointRoot(id), isNotNull);
      final after = await chapters.read(0);
      await chapters.rename(after, after.nodes.first.id, '第一章 压缩后');

      // 原来遇到检查点就拒绝清理；现在预览与采用都分两段换算。
      await applyCleanup(library, id);
      expect(state.cleanup.drafts[id], isNotNull);
      expect(await firstTitle(library, id), '第一章 压缩后');
      expect((await firstBody(library, id)).first, '甲文');
      final cleanup = library.openCleanup(id);
      try {
        await cleanup.undo();
        expect(state.cleanup.drafts[id], isNull);
        expect(await firstTitle(library, id), '第一章 压缩后');
        expect((await firstBody(library, id)).first, '甲文  ');
      } finally {
        cleanup.dispose();
      }
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  test('批量清理逐本换算；无法换算的书须逐本决定，不替用户决定（CLEAN-104）', () async {
    final (state, library, ids) = await open('v17-batch-', 3);
    try {
      // ids[1] 只改名；ids[2] 改名并删除第 4 行的空行（清理会把它合并掉）。
      for (final id in [ids[1], ids[2]]) {
        final chapters = library.openChapters(id);
        final page = await chapters.read(0);
        await chapters.rename(page, page.nodes.first.id, '第一章 改名');
      }
      final third = library.openChapters(ids[2]);
      final renamed = await third.read(0);
      await third.confirm(
        await third.preview(
          renamed,
          ExcludeChapterBodyLines(renamed.nodes.first.id, 3, 3),
        ),
      );
      final batch = library.openCleanupBatch(ids[0]);
      try {
        final plan = await batch.preview(
          jsonEncode(pipeline),
          ids,
          append: false,
        );
        expect(plan.ready, true);
        final items = {for (final item in plan.items) item.bookId: item};
        expect(items[ids[0]]!.editsKept, 0);
        expect(items[ids[0]]!.needsDecision, false);
        expect(items[ids[1]]!.editsKept, 1);
        expect(items[ids[1]]!.needsDecision, false);
        expect(items[ids[2]]!.editsKept, 1);
        expect(items[ids[2]]!.needsDecision, true);
        expect(items[ids[2]]!.skippedEdits.single.action, '删除正文行');
        // 没有决定时不采用整批，状态不变。
        final drafts = jsonEncode(state.cleanup.drafts);
        await expectLater(batch.apply(plan), throwsFormatException);
        expect(jsonEncode(state.cleanup.drafts), drafts);
        // 预览仍然有效：用户决定后可以直接采用同一份预览。
        expect(batch.isCurrent(plan), true);
        await batch.apply(plan, dropEdits: {ids[2]});
        for (final id in ids) {
          expect(state.cleanup.drafts[id], isNotNull, reason: id);
          expect((await firstBody(library, id)).first, '甲文');
        }
        expect(await firstTitle(library, ids[1]), '第一章 改名');
        expect(await firstTitle(library, ids[2]), '第一章 改名');
        expect(
          state.cleanup.historyStatus[ids[2]],
          contains('1 处章节修改已换算到清理后的文本，放弃 1 处'),
        );
        // 逐书撤销仍会换算章节修改。
        final cleanup = library.openCleanup(ids[1]);
        try {
          await cleanup.undo();
          expect(await firstTitle(library, ids[1]), '第一章 改名');
        } finally {
          cleanup.dispose();
        }
      } finally {
        batch.dispose();
      }
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  testWidgets('批量清理对话框：无法换算的书显示“需要你决定”，决定前不能确认采用（CLEAN-104）', (t) async {
    t.view.physicalSize = const Size(1100, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late List<String> ids;
    await t.runAsync(() async {
      (state, library, ids) = await open('v17-batch-ui-', 2);
      final chapters = library.openChapters(ids[1]);
      final page = await chapters.read(0);
      await chapters.rename(page, page.nodes.first.id, '第一章 改名');
      final renamed = await chapters.read(0);
      await chapters.confirm(
        await chapters.preview(
          renamed,
          ExcludeChapterBodyLines(renamed.nodes.first.id, 3, 3),
        ),
      );
      for (final id in ids) {
        library.checkBook(id, true);
      }
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> settle() async {
      for (var i = 0; i < 400; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
        if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
          await t.pumpAndSettle();
          return;
        }
      }
      fail('batch still busy');
    }

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<Set<String>>(
                context: context,
                builder: (_) => CleanupBatchDialog(
                  library: library,
                  bookId: ids.first,
                  template: jsonEncode(pipeline),
                ),
              ),
              child: const Text('打开批量'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开批量'));
    await t.pumpAndSettle();
    await t.tap(find.text('逐书预览'));
    await t.pump();
    await settle();
    expect(find.text('需要你决定'), findsOneWidget);
    expect(
      find.byKey(ValueKey('batch-edits-decision-${ids[1]}')),
      findsOneWidget,
    );
    final confirm = find.byType(CheckboxListTile);
    expect(t.widget<CheckboxListTile>(confirm).onChanged, isNull);
    await t.tap(find.byKey(ValueKey('batch-drop-edits-${ids[1]}')));
    await t.pumpAndSettle();
    expect(find.text('已选择：放弃这些修改并清理'), findsOneWidget);
    expect(t.widget<CheckboxListTile>(confirm).onChanged, isNotNull);
    await t.ensureVisible(find.text('已核对逐书预览，确认采用本批清理规则'));
    await t.pumpAndSettle();
    await t.tap(find.text('已核对逐书预览，确认采用本批清理规则'));
    await t.pump();
    await t.tap(find.text('确认采用'));
    await t.pump();
    await settle();
    expect(find.byType(CleanupBatchDialog), findsNothing);
    for (final id in ids) {
      expect(state.cleanup.drafts[id], isNotNull, reason: id);
    }
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  // 第二章“番外”连续出现两次（中间只有空行）；第三、四章和第六章缺号；第五章带后缀。
  const exceptions =
      '第一章 夜渡\n甲文\n第二章 番外\n\n第二章 番外\n乙文\n第五章 远行（求月票）\n丙文\n第七章 归来\n丁文\n';

  Future<(PrototypeState, LegacyLibraryAdapter, String)> openExceptions(
    String prefix,
  ) async {
    final root = (await Directory('../artifacts').createTemp(prefix)).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    await library.load();
    await library.savePatch({'check_after_import': false});
    final file = File('${root.path}/例外.txt')..writeAsStringSync(exceptions);
    expect((await library.importFiles([file.path])).single.succeeded, true);
    return (state, library, state.currentId);
  }

  test('识别规则例外：允许的重复标题与编号跳跃不再报，标题后缀只改标题（CH-258–260）', () async {
    final (state, library, id) = await openExceptions('v17-exceptions-');
    try {
      final rules = library.openRules(id);
      final base = Map<String, dynamic>.from(
        (await rules.load())['rules'] as Map,
      );
      // 三项留空：规则指纹与不填时相同。
      final plain = await (rules as dynamic).request({
        'op': 'validate',
        'rules': base,
      });
      final empty = await (rules as dynamic).request({
        'op': 'validate',
        'rules': {
          ...base,
          'allowed_duplicate_titles': '',
          'allowed_number_gaps': '',
          'title_suffixes': '',
        },
      });
      expect(empty['fingerprint'], plain['fingerprint']);
      await expectLater(
        rules.preview({
          ...base,
          'allowed_number_gaps': '五-三',
        }, preserveDecisions: true),
        throwsA(isA<FormatException>()),
      );

      Future<Map<String, int>> counts() async {
        final chapters = library.openChapters(id);
        final page = await chapters.read(0);
        return (await chapters.issues(page, 0, effective: true)).categoryCounts;
      }

      final before = await counts();
      expect(before['duplicate-title'], 1);
      expect(before['number-gap'], 2);

      final preview = await rules.preview({
        ...base,
        'allowed_duplicate_titles': '番外',
        'allowed_number_gaps': '3-4',
        'title_suffixes': '（求月票）',
      }, preserveDecisions: true);
      // 差异页列出被清理的标题，并写出两项检查的前后数量。
      final changes = (preview.data['changes'] as List).cast<Map>();
      expect(changes.single['kind'], 'changed');
      expect(changes.single['before'], '第五章 远行（求月票）');
      expect(changes.single['after'], '第五章 远行');
      expect(
        {
          for (final c in (preview.data['check_changes'] as List).cast<Map>())
            c['id']: [c['before'], c['after']],
        },
        {
          'duplicate-title': [1, 0],
          'number-gap': [2, 1],
        },
      );
      await rules.apply(preview);

      final after = await counts();
      expect(after['duplicate-title'] ?? 0, 0);
      // 第六章不在允许列表里，仍报。
      expect(after['number-gap'], 1);
      final chapters = library.openChapters(id);
      final page = await chapters.read(0);
      expect(page.nodes.map((n) => n.title), [
        '第一章 夜渡',
        '第二章 番外',
        '第二章 番外',
        '第五章 远行',
        '第七章 归来',
      ]);
      // 只改标题：正文不变。
      final fifth = page.nodes.firstWhere((n) => n.title == '第五章 远行');
      expect((await chapters.body(page, fifth.id, 0)).lines, ['丙文']);
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  testWidgets('识别规则面板：“例外”折叠区三项输入，试匹配显示检查数量变化（CH-258–260）', (t) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      (state, library, id) = await openExceptions('v17-exceptions-ui-');
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 400; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
        if (ready()) {
          await t.pumpAndSettle();
          return;
        }
      }
      fail('rules sheet still busy');
    }

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showChapterRulesDialog(context, service: library, bookId: id),
              child: const Text('打开规则'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开规则'));
    await until(() => find.text('例外').evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('rules-help-例外')), findsOneWidget);
    // 默认收起；留空的规则不展开。
    expect(find.byKey(const ValueKey('rules-title_suffixes')), findsNothing);
    await t.ensureVisible(find.text('例外'));
    await t.tap(find.text('例外'));
    await t.pumpAndSettle();
    for (final (key, text) in [
      ('allowed_duplicate_titles', '番外'),
      ('allowed_number_gaps', '3-4'),
      ('title_suffixes', '（求月票）'),
    ]) {
      final field = find.byKey(ValueKey('rules-$key'));
      await t.ensureVisible(field);
      await t.enterText(field, text);
      await t.pump();
    }
    await t.tap(find.text('全书试匹配与差异'));
    await until(
      () => find
          .byKey(const ValueKey('rules-check-change-duplicate-title'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.text('检查：连续重复标题 1 处 → 0 处'), findsOneWidget);
    expect(find.text('检查：章节编号跳跃 2 处 → 1 处'), findsOneWidget);
    expect(find.textContaining('原标题：第五章 远行（求月票）'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
