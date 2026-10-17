import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/prototype/kindling_job.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/desk/conversion/tasks_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class TestChanges extends ChangeNotifier {
  void refresh() => notifyListeners();
}

class Session extends Fake implements ConversionSession {
  @override
  final TestChanges changes = TestChanges();
  @override
  bool busy = true;
  bool runChecks = true;
  @override
  List<ConversionOutput> outputs = [];
  @override
  ConversionRequest get request => ConversionRequest(
    books: ['book'],
    directory: 'D:/output',
    format: 'MOBI',
    runChecks: runChecks,
  );
}

class Desktop extends Fake implements ConversionDesktop {
  String? opened;
  @override
  Future<void> openDirectory(String path) async => opened = path;
}

class FeedSession extends Session implements ConversionTaskFeed {
  Completer<void>? loaded;
  @override
  Future<void> loadTaskFeed() async {
    await loaded?.future;
  }

  @override
  String get taskFeedStatus => '';
  @override
  List<ConversionOutput> taskFeed = [];
}

void main() {
  testWidgets(
    'async history refreshes without notifications and opens a drive root',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = FeedSession()
        ..busy = false
        ..loaded = Completer<void>();
      final desktop = Desktop();
      addTearDown(session.changes.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: TasksPage(
              session: session,
              desktop: desktop,
              onAdd: () {},
              onRetry: (_) {},
              onHistory: () {},
              onOutput: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('尚无转换批次，请先选择书稿开始转换。'), findsOneWidget);
      session.taskFeed = [
        const ConversionOutput(
          'book',
          '根目录成品',
          'D:/book.epub',
          '已完成',
          phase: 'complete',
          taskId: 'root',
          format: 'EPUB',
          historical: true,
        ),
      ];
      session.loaded!.complete();
      await tester.pumpAndSettle();
      expect(find.text('根目录成品'), findsNWidgets(2));
      await tester.ensureVisible(find.text('打开成品目录'));
      await tester.tap(find.text('打开成品目录'));
      await tester.pumpAndSettle();
      expect(desktop.opened, 'D:/');
      session.taskFeed.add(
        const ConversionOutput(
          'failed',
          '失败书稿',
          '',
          '失败',
          phase: 'failed',
          taskId: 'failed',
          format: 'EPUB',
          historical: true,
        ),
      );
      tester.view.physicalSize = const Size(820, 480);
      session.changes.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.text('失败书稿').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('重试此项'));
      expect(tester.getRect(find.text('重试此项')).bottom, lessThanOrEqualTo(480));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mixed task feed selects historical identity and its own output directory',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = FeedSession();
      addTearDown(session.changes.dispose);
      final desktop = Desktop();
      String? openedTask;
      session.outputs = [
        const ConversionOutput(
          'book',
          '同一本书',
          'D:/current/book.mobi',
          '生成中',
          taskId: 'current',
          phase: 'converting',
          format: 'MOBI',
          checksEnabled: false,
        ),
      ];
      session.taskFeed = [
        ...session.outputs,
        const ConversionOutput(
          'book',
          '同一本书',
          'D:/older/book.epub',
          '已完成',
          taskId: 'history',
          phase: 'complete',
          format: 'EPUB',
          historical: true,
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: TasksPage(
              session: session,
              desktop: desktop,
              onAdd: () {},
              onRetry: (_) {},
              onHistory: () {},
              onOutput: (id) => openedTask = id,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('当前及最近任务'), findsOneWidget);
      expect(find.text('未启用 · 直接转换'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('task-row-history')));
      await tester.pump();
      expect(find.text('未记录检查策略'), findsOneWidget);
      expect(find.text('未启用 · 直接转换'), findsNothing);
      await tester.tap(find.text('打开成品目录'));
      await tester.pump();
      expect(desktop.opened, 'D:/older');
      await tester.tap(find.text('成品验收'));
      expect(openedTask, 'history');
      expect(session.outputs.single.taskId, 'current');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('poll failure retains handle and phase; cancellation waits for terminal evidence', () async {
    final disconnected = Completer<void>();
    final resume = Completer<Map<String, dynamic>>();
    var starts = 0, polls = 0, forgotten = 0, cancelCalls = 0;
    late KindlingJob job;
    job = KindlingJob(
      onChanged: () {
        if (!job.statusAvailable && !disconnected.isCompleted) {
          disconnected.complete();
        }
      },
      call: (request) async {
        switch (request['op']) {
          case 'start':
            starts++;
            return {'job_id': 7};
          case 'cancel':
            cancelCalls++;
            return {'accepted': true};
          case 'forget':
            forgotten++;
            return {};
          case 'status':
            polls++;
            if (polls == 1) {
              return {
                'phase': 'converting',
                'terminal': false,
                'cancellable': true,
              };
            }
            if (polls == 2) throw StateError('transport unavailable');
            if (polls == 3) return resume.future;
            return {
              'phase': 'cancelled',
              'terminal': true,
              'cancellable': false,
            };
          default:
            throw StateError('unexpected operation');
        }
      },
    );
    final running = job.run({});
    final ended = expectLater(running, throwsA(isA<ExportStopped>()));
    await disconnected.future;
    expect(job.id, 7);
    expect(job.phase, 'converting');
    expect(job.terminal, isFalse);
    await job.cancel();
    expect(job.cancelRequested, isTrue);
    expect(job.terminal, isFalse);
    resume.complete({
      'phase': 'converting',
      'terminal': false,
      'cancellable': true,
    });
    await ended;
    expect(job.statusAvailable, isTrue);
    expect(job.phase, 'cancelled');
    expect(job.terminal, isTrue);
    expect(starts, 1);
    expect(cancelCalls, 1);
    expect(forgotten, 1);
  });
  testWidgets(
    'task list and stages distinguish disconnected, cancel requested and cancelled',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = Session();
      addTearDown(session.changes.dispose);
      ConversionOutput output({
        bool available = true,
        bool cancel = false,
        String phase = 'converting',
      }) => ConversionOutput(
        'book',
        '样书',
        'D:/output/book.mobi',
        '正在生成',
        taskId: 'one',
        phase: phase,
        format: 'MOBI',
        statusAvailable: available,
        cancelRequested: cancel,
        checksEnabled: session.runChecks,
        detail: available ? '' : '任务状态暂时无法获取，正在重新连接…',
      );
      session.outputs = [output(available: false)];
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: TasksPage(
              session: session,
              desktop: Desktop(),
              onAdd: () {},
              onRetry: (_) {},
              onHistory: () {},
              onOutput: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('状态暂不可用'), findsOneWidget);
      expect(find.text('等待状态更新'), findsOneWidget);
      expect(find.text('任务状态暂时无法获取，正在重新连接…'), findsNWidgets(2));
      expect(find.text('已启用 · 质量问题不限制转换'), findsOneWidget);
      session.runChecks = false;
      session.outputs = [output(cancel: true)];
      session.changes.refresh();
      await tester.pump();
      expect(find.text('正在取消'), findsOneWidget);
      expect(find.text('等待取消结果'), findsOneWidget);
      expect(find.text('等待状态更新'), findsNothing);
      expect(find.text('未启用 · 直接转换'), findsOneWidget);
      expect(find.text('已请求取消 · 等待后台确认'), findsOneWidget);
      session.outputs = [output(cancel: true, phase: 'cancelled')];
      session.busy = false;
      session.changes.refresh();
      await tester.pump();
      expect(find.text('等待取消结果'), findsNothing);
      expect(find.text('重试此项'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
