import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/desk/conversion/tasks_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class StopChanges extends ChangeNotifier {
  void publish() => notifyListeners();
}

class StopSession extends Fake implements ConversionSession {
  @override
  final StopChanges changes = StopChanges();
  @override
  bool busy = true;
  @override
  List<ConversionOutput> outputs = [
    const ConversionOutput(
      'a',
      '当前文件',
      'D:/a.epub',
      '转换中',
      format: 'EPUB',
      phase: 'converting',
    ),
  ];
  @override
  Future<void> cancel() async {
    outputs = [
      const ConversionOutput(
        'a',
        '当前文件',
        'D:/a.epub',
        '转换中',
        format: 'EPUB',
        phase: 'converting',
        stopRequested: true,
      ),
    ];
    changes.publish();
  }

  void finish() {
    busy = false;
    outputs = [
      const ConversionOutput(
        'a',
        '当前文件',
        'D:/a.epub',
        '已完成',
        format: 'EPUB',
        phase: 'complete',
      ),
      const ConversionOutput(
        'b',
        '尚未执行',
        'D:/b.epub',
        '已取消',
        format: 'EPUB',
        phase: 'cancelled',
      ),
    ];
    changes.publish();
  }
}

class StopDesktop extends Fake implements ConversionDesktop {}

void main() {
  for (final size in [const Size(1440, 960), const Size(1080, 720)]) {
    testWidgets(
      'task page distinguishes deferred EPUB stop and cancelled filter at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final session = StopSession();
        addTearDown(session.changes.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: deskTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(size.width == 1080 ? 1.3 : 1),
              ),
              child: child!,
            ),
            home: Scaffold(
              body: TasksPage(
                session: session,
                desktop: StopDesktop(),
                onAdd: () {},
                onRetry: (_) {},
                onHistory: () {},
                onOutput: (_) {},
              ),
            ),
          ),
        );
        await tester.ensureVisible(find.text('停止队列'));
        await tester.tap(find.text('停止队列'));
        await tester.pump();
        expect(find.text('当前文件完成后停止'), findsWidgets);
        expect(find.textContaining('等待当前文件处理结束'), findsOneWidget);
        expect(find.text('正在取消'), findsNothing);
        final button = tester.widget<TextButton>(
          find.ancestor(
            of: find.text('等待停止完成'),
            matching: find.byType(TextButton),
          ),
        );
        expect(button.onPressed, isNull);
        expect(find.byType(LinearProgressIndicator), findsWidgets);
        expect(tester.takeException(), isNull);
        session.finish();
        await tester.pumpAndSettle();
        expect(find.text('当前文件完成后停止'), findsNothing);
        await tester.ensureVisible(find.text('已取消 1'));
        await tester.tap(find.text('已取消 1'));
        await tester.pumpAndSettle();
        expect(find.text('尚未执行'), findsWidgets);
        expect(find.text('当前文件'), findsNothing);
        // 取消不算失败；V16 起数量为 0 的分类不显示（TASK-024）。
        expect(find.textContaining(RegExp(r'^失败 ')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  test('publishing stop differs from accepted cancellation and terminal status wins', () {
    const saving = ConversionOutput(
      'a',
      'a',
      'a',
      '保存中',
      format: 'MOBI',
      phase: 'publishing',
      stopRequested: true,
    );
    const cancelling = ConversionOutput(
      'a',
      'a',
      'a',
      '转换中',
      format: 'MOBI',
      phase: 'converting',
      stopRequested: true,
      cancelRequested: true,
    );
    const finished = ConversionOutput(
      'a',
      'a',
      'a',
      '已完成',
      format: 'MOBI',
      phase: 'complete',
      stopRequested: true,
      cancelRequested: true,
    );
    expect(taskStatusLabel(saving), '当前文件完成后停止');
    expect(taskStatusLabel(cancelling), '正在取消');
    expect(taskStatusLabel(finished), '已完成');
  });
}
