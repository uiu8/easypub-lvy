import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/checks/batch_repair_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class _Session implements ChapterSession {
  bool failConfirm = false;
  int confirms = 0;
  static const tree = ChapterPage([], 2, 0, 'revision');
  static const change = ChapterRepairChange(
    'finding',
    'node',
    '第一章 甲',
    2,
    1,
    '第一章 甲\n第一章 甲',
    '第一章 甲',
    false,
  );
  static const judged = ChapterRepairChange(
    'judged',
    'node',
    '第二章 乙',
    9,
    8,
    '第二章 乙',
    '第二章 丙',
    false,
    recommended: false,
  );
  @override
  Future<ChapterPage> read(
    int offset, {
    bool includeBody = false,
    String? preferredNodeId,
  }) async => tree;
  @override
  Future<ChapterRepairOptions> repairs(ChapterPage page) async =>
      const ChapterRepairOptions(
        [change, judged],
        2,
        ChapterIssuePage([], 3, 0, effective: true),
      );
  @override
  Future<ChapterRepairPlan> previewRepairs(
    ChapterRepairOptions options,
    Set<String> selectedIds,
  ) async => ChapterRepairPlan(const ChapterEditPreview(), [
    for (final c in options.changes)
      if (selectedIds.contains(c.id)) c,
  ]);
  @override
  Future<void> confirm(ChapterEditPreview preview) async {
    confirms++;
    if (failConfirm) {
      throw const FormatException('injected application rejection');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('一键修复：应用失败不关闭，要重新预览确认；要判断的默认不选', (tester) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = _Session()..failConfirm = true;
    Object? result = 'open';
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<Object?>(
                  context: context,
                  builder: (_) => BatchRepairDialog(session: session),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    Future<void> tap(String text) async {
      await tester.tap(find.text(text));
      await tester.pumpAndSettle();
    }

    await tap('打开');
    expect(find.text('一键修复'), findsOneWidget);
    expect(find.text('已选 1 / 2 项'), findsOneWidget, reason: '要判断的默认不选');
    expect(find.text('需要你判断'), findsOneWidget);
    expect(find.text('另有 1 个问题没有自动方案，要在“问题”里逐条核对。'), findsOneWidget);

    await tap('预览 1 项修改');
    await tap('应用 1 项修改');
    expect(session.confirms, 1);
    expect(find.byType(BatchRepairDialog), findsOneWidget, reason: '失败不关闭');
    expect(
      find.textContaining('injected application rejection'),
      findsOneWidget,
    );
    expect(find.text('应用 1 项修改'), findsNothing, reason: '失败的方案不能再提交');

    session.failConfirm = false;
    await tap('预览 1 项修改');
    await tap('应用 1 项修改');
    expect(session.confirms, 2);
    expect(find.byType(BatchRepairDialog), findsNothing);
    expect(result, isNot('open'));
    expect(tester.takeException(), isNull);
  });
}
