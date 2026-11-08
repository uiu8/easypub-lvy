import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/desk/conversion/tasks_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/widgets.dart';

class RowChanges extends ChangeNotifier {}

class FailedSession extends Fake implements ConversionSession {
  @override
  final RowChanges changes = RowChanges();
  @override
  bool busy = false;
  @override
  List<ConversionOutput> outputs = [
    const ConversionOutput(
      'a',
      '一本书名相当长的测试书稿',
      'D:/a.azw3',
      // 失败任务的状态是“失败：详情”（output_batch.dart），详情可能很长。
      '失败：Kindling 转换进程意外退出，未生成成品文件，请查看日志后重试',
      format: 'AZW3',
      phase: 'failed',
      detail: 'Kindling 转换进程意外退出，未生成成品文件，请查看日志后重试',
      taskId: 't1',
    ),
    const ConversionOutput(
      'b',
      '正常完成',
      'D:/b.epub',
      '已完成',
      format: 'EPUB',
      phase: 'complete',
      taskId: 't2',
    ),
  ];
}

class RowDesktop extends Fake implements ConversionDesktop {}

Future<void> pumpTasks(WidgetTester tester, FailedSession session) =>
    tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: TasksPage(
            session: session,
            desktop: RowDesktop(),
            onAdd: () {},
            onRetry: (_) {},
            onHistory: () {},
            onOutput: (_) {},
          ),
        ),
      ),
    );

/// 任务行里封面、标题与状态标签所在的那一行。
Finder rowOf(String taskId) => find
    .descendant(
      of: find.byKey(ValueKey('task-row-$taskId')),
      matching: find.byType(Row),
    )
    .first;

void main() {
  testWidgets('failed task row at 362 wide keeps long status inside the row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = FailedSession();
    addTearDown(session.changes.dispose);
    await pumpTasks(tester, session);
    await tester.pumpAndSettle();
    // 与 quick_conversion_test 偶发失败时的日志一致：行宽 362。
    expect(tester.getSize(rowOf('t1')).width, 362);
    expect(tester.takeException(), isNull);
    // 标签不越出行的右边，标题仍有位置显示。
    final row = tester.getRect(rowOf('t1'));
    final tag = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('task-row-t1')),
        matching: find.byType(DeskTag),
      ),
    );
    expect(tag.right, lessThanOrEqualTo(row.right));
    final title = tester.getRect(find.text('一本书名相当长的测试书稿'));
    expect(title.width, greaterThan(100));
    // 截断时悬停可看到完整状态。
    expect(
      find.byTooltip('失败：Kindling 转换进程意外退出，未生成成品文件，请查看日志后重试'),
      findsOneWidget,
    );
    // 短标签照常完整显示。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('task-row-t2')),
        matching: find.text('已完成'),
      ),
      findsOneWidget,
    );
  });
}
