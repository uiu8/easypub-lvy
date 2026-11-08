import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/desk/conversion/tasks_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class RetryChanges extends ChangeNotifier {
  void publish() => notifyListeners();
}

class RetrySession extends Fake
    implements ConversionSession, ConversionRetryService {
  @override
  final RetryChanges changes = RetryChanges();
  @override
  bool busy = false;
  @override
  ConversionRequest? request;
  @override
  List<ConversionOutput> outputs = [
    const ConversionOutput(
      'same',
      'A任务',
      'D:/A.epub',
      '失败',
      phase: 'failed',
      format: 'EPUB',
      taskId: 'task-A',
      batchId: 'A',
    ),
    const ConversionOutput(
      'same',
      'B任务',
      'D:/B.mobi',
      '失败',
      phase: 'failed',
      format: 'MOBI',
      taskId: 'task-B',
      batchId: 'B',
    ),
    const ConversionOutput(
      'other',
      '取消任务',
      'D:/cancel.epub',
      '已取消',
      phase: 'cancelled',
      format: 'EPUB',
      taskId: 'task-cancel',
      batchId: 'A',
    ),
  ];
  List<String> received = [];
  int commits = 0, cancels = 0;
  bool block = false;
  @override
  Future<ConversionPreview> previewRetry(List<String> ids) async {
    received = ids;
    if (block) throw const FormatException("原稿已变化，请重新配置转换。");
    final chosen = outputs.where((o) => ids.contains(o.taskId)).toList();
    request = ConversionRequest(
      books: chosen.map((o) => o.bookId).toList(),
      directory: chosen.single.batchId == 'A'
          ? 'D:/original-A'
          : 'D:/original-B',
      format: chosen.single.format,
      runChecks: false,
    );
    return ConversionPreview(
      [
        ConversionFinding(
          chosen.single.bookId,
          '检查提醒',
          'warning',
          '保留原目录并核对章节',
          null,
        ),
      ],
      chosen,
      previewed: true,
    );
  }

  @override
  Future<List<ConversionOutput>> commit(
    ConversionPreview plan, {
    required bool acknowledgeWarnings,
  }) async {
    expect(acknowledgeWarnings, true);
    commits++;
    return plan.outputs;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }
}

class RetryDesktop extends Fake implements ConversionDesktop {}

void main() {
  testWidgets(
    'retry uses selected batch task identities and requires original-settings confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = RetrySession();
      addTearDown(session.changes.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: TasksPage(
              session: session,
              desktop: RetryDesktop(),
              onAdd: () {},
              onRetry: (_) => fail('Should use exact task retry capability'),
              onHistory: () {},
              onOutput: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('重试本批次失败项'));
      await tester.pumpAndSettle();
      expect(session.received, ['task-A']);
      expect(session.commits, 0);
      expect(find.textContaining('D:/original-A'), findsOneWidget);
      expect(find.textContaining('保留原目录并核对章节'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(session.commits, 0);
      expect(session.cancels, 1);
      await tester.tap(find.text('B任务').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试本批次失败项'));
      await tester.pumpAndSettle();
      expect(session.received, ['task-B']);
      expect(find.textContaining('D:/original-B'), findsOneWidget);
      await tester.tap(find.text('确认重试'));
      await tester.pumpAndSettle();
      expect(session.commits, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('blocked retry offers an explicit new batch without committing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = RetrySession()..block = true;
    addTearDown(session.changes.dispose);
    List<String>? reconfigured;
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: TasksPage(
            session: session,
            desktop: RetryDesktop(),
            onAdd: () {},
            onRetry: (ids) => reconfigured = ids,
            onHistory: () {},
            onOutput: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('重试本批次失败项'));
    await tester.pumpAndSettle();
    expect(find.text('无法按原配置重试'), findsOneWidget);
    expect(find.textContaining('原稿已变化'), findsWidgets);
    expect(session.commits, 0);
    expect(reconfigured, isNull);
    await tester.tap(find.text('返回任务'));
    await tester.pumpAndSettle();
    expect(reconfigured, isNull);
    await tester.tap(find.text('重试本批次失败项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用当前书稿重新配置'));
    await tester.pumpAndSettle();
    expect(reconfigured, ['same']);
    expect(session.commits, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'cancelled unstarted item routes explicitly to new configuration',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = RetrySession()
        ..outputs = [
          const ConversionOutput(
            'not-started',
            '未开始书',
            'D:/none.epub',
            '已取消',
            phase: 'cancelled',
            format: 'EPUB',
            batchId: 'A',
          ),
        ];
      addTearDown(session.changes.dispose);
      List<String>? reconfigured;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: TasksPage(
              session: session,
              desktop: RetryDesktop(),
              onAdd: () {},
              onRetry: (ids) => reconfigured = ids,
              onHistory: () {},
              onOutput: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('重试此项'));
      await tester.pumpAndSettle();
      expect(find.textContaining('没有任务回执'), findsWidgets);
      expect(session.received, isEmpty);
      await tester.tap(find.text('使用当前书稿重新配置'));
      await tester.pumpAndSettle();
      expect(reconfigured, ['not-started']);
      expect(session.commits, 0);
    },
  );
}
