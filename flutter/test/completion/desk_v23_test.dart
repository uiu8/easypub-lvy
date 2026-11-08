import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/folders/folder_import_dialog.dart';
import 'package:easypub_desktop/desk/library/book_summary_panel.dart';
import 'package:easypub_desktop/desk/rules/rules_summary.dart';

import 'library_removal_test.dart' as fixtures;

class _UnusedPicker implements BookFilePicker {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 六行样例列表：与生产列表相同的表头、快捷键与 Shift 选段。
class _Sample extends StatefulWidget {
  const _Sample({required this.onEscape});
  final VoidCallback onEscape;
  @override
  State<_Sample> createState() => _SampleState();
}

class _SampleState extends State<_Sample> {
  final items = List.generate(6, (i) => '第$i项');
  final selected = <String>{};
  final range = RangeSelection();
  void setMany(Iterable<String> ids, bool v) =>
      setState(() => v ? selected.addAll(ids) : selected.removeAll(ids));

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): widget.onEscape,
    },
    child: Focus(
      autofocus: true,
      child: SelectionKeys(
        hasSelection: selected.isNotEmpty,
        onSelectAll: () => setMany(items, true),
        onClear: () => setMany(items, false),
        child: Column(
          children: [
            SelectAllHeader(
              selected: selected.length,
              total: items.length,
              onChanged: (v) => setMany(items, v),
            ),
            for (var i = 0; i < items.length; i++)
              Row(
                children: [
                  Checkbox(
                    key: ValueKey('row-$i'),
                    value: selected.contains(items[i]),
                    onChanged: (v) => setMany([
                      for (final j in range.span(i)) items[j],
                    ], v == true),
                  ),
                  Text(items[i]),
                ],
              ),
          ],
        ),
      ),
    ),
  );
}

/// V23：列表三态全选与默认勾选（G-067/068）、识别规则入口（CH-261/262）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('识别规则摘要按生效规则生成（CH-261）', () {
    expect(rulesSummary({}), '内置');
    expect(rulesSummary({'numeric': true}), '内置 · 纯数字');
    expect(
      rulesSummary({'volume_pattern': r'^卷(?<number>\d+)$'}),
      '内置 · 自定义层级',
    );
    expect(
      rulesSummary({
        'chapter_pattern': r'^第(?<number>\d+)话$',
        'numeric': true,
        'allowed_duplicate_titles': '番外\n\n后记',
        'allowed_number_gaps': '9、101-104，200',
        'title_suffixes': '（求月票）',
        'non_heading': '两章合一章',
      }),
      '自定义正则 · 纯数字 · 例外 6 · 词库 1',
    );
  });

  testWidgets('表头三态、Ctrl+A、Esc 与 Shift 选一段（G-067）', (t) async {
    var escaped = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _Sample(onEscape: () => escaped++)),
      ),
    );
    final header = find.byKey(const ValueKey('select-all'));
    Checkbox box() => t.widget<Checkbox>(header);
    expect(find.text('0 / 6'), findsOneWidget);
    expect(box().value, false);

    await t.tap(header);
    await t.pump();
    expect(find.text('6 / 6'), findsOneWidget);
    expect(box().value, true);
    await t.tap(header);
    await t.pump();
    expect(find.text('0 / 6'), findsOneWidget);

    // 点第 1 行，按住 Shift 点第 4 行：1–4 共 4 行勾选，表头为部分勾选。
    await t.tap(find.byKey(const ValueKey('row-1')));
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.tap(find.byKey(const ValueKey('row-4')));
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(find.text('4 / 6'), findsOneWidget);
    expect(box().value, isNull);
    expect(
      t.widget<Checkbox>(find.byKey(const ValueKey('row-0'))).value,
      false,
    );
    expect(
      t.widget<Checkbox>(find.byKey(const ValueKey('row-5'))).value,
      false,
    );

    // 有勾选时 Esc 清空且不往上传；没有勾选时 Esc 交给上层（例如关闭弹窗）。
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.text('0 / 6'), findsOneWidget);
    expect(escaped, 0);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(escaped, 1);

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(find.text('6 / 6'), findsOneWidget);
  });

  testWidgets('导入文件夹：表头全选、书库已有不可勾选、规则图标；书库详情的规则图标（G-067/068，CH-262）', (
    t,
  ) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final fixture = await t.runAsync(fixtures.fixture);
    final (state, library, root) = fixture!;
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    // 夹具的书“甲”“乙”就在 root 下，扫描 root（不含子文件夹）时它们是书库已有的书。
    final input = Directory(root);
    await t.runAsync(() async {
      for (final name in ['丙', '丁', '戊']) {
        File('${input.path}/$name.txt').writeAsStringSync('第一章 开始\n$name正文\n');
      }
    });
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 500; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
        if (ready()) {
          await t.pump(const Duration(milliseconds: 300));
          return;
        }
      }
      fail('没有等到');
    }

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: FolderImportDialog(
            library: library,
            picker: _UnusedPicker(),
            initialPath: input.path,
          ),
        ),
      ),
    );
    await until(() => find.text('3 / 3').evaluate().isNotEmpty);
    // 新书默认全选；书库已有的不计入可选数，并在表头说明。
    expect(find.text('导入所选 3 本'), findsOneWidget);
    expect(find.textContaining('书库已有 2 本不可勾选'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('select-all')));
    await t.pump();
    expect(find.text('0 / 3'), findsOneWidget);
    expect(find.text('导入所选 0 本'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('select-all')));
    await t.pump();
    expect(find.text('导入所选 3 本'), findsOneWidget);

    // 规则图标：打开导入默认规则。
    expect(find.byTooltip('导入默认识别规则'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('folder-import-rules')));
    await until(() => find.text('导入默认规则').evaluate().isNotEmpty);
    await t.tap(find.byTooltip('关闭（未应用的规则草稿会保留）'));
    await t.pump(const Duration(milliseconds: 400));

    // 书库详情：规则图标打开这本书的识别规则。
    final book = library.books.value.first;
    String? opened;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: BookSummaryPanel(
              book: book,
              open: (page) => opened = page,
              library: library,
              headingHeight: 40,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byTooltip('本书识别规则'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('book-summary-rules')));
    await until(() => find.text('本书识别规则').evaluate().isNotEmpty);
    expect(opened, isNull);
    await t.tap(find.byTooltip('关闭（未应用的规则草稿会保留）'));
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('目录标题行的识别规则摘要：显示摘要、点击打开、改规则后刷新（CH-261）', (t) async {
    final fixture = await t.runAsync(fixtures.fixture);
    final (state, library, _) = fixture!;
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = library.books.value.first.id;
    var opened = 0;
    Future<void> pump(int revision, int headings, double width) async {
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: RulesSummaryChip(
                    service: library,
                    bookId: id,
                    headings: headings,
                    revision: revision,
                    onOpen: () => opened++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 30; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump();
      }
    }

    await pump(0, 1, 300);
    expect(find.text('内置'), findsOneWidget);
    expect(find.byKey(const ValueKey('chapter-rules-hint')), findsNothing);
    await t.tap(find.byKey(const ValueKey('chapter-rules-summary')));
    expect(opened, 1);

    // 应用一套带“纯数字”的规则后，递增 revision 重新读取。
    final session = library.openRules(id);
    await t.runAsync(() async {
      final data = await session.load();
      final rules = {
        ...(data['rules'] as Map).cast<String, dynamic>(),
        'numeric': true,
      };
      await session.apply(
        await session.preview(rules, preserveDecisions: true),
      );
    });
    await pump(1, 0, 300);
    expect(find.text('内置 · 纯数字'), findsOneWidget);
    // 没有识别出章节时有提示圆点。
    expect(find.byKey(const ValueKey('chapter-rules-hint')), findsOneWidget);
    // 窄栏只留图标。
    await pump(1, 0, 90);
    expect(find.text('内置 · 纯数字'), findsNothing);
    expect(find.byKey(const ValueKey('chapter-rules-summary')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
