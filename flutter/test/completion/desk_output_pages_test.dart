import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/application/output_history_service.dart';
import 'package:easypub_desktop/desk/conversion/output_acceptance_page.dart';
import 'package:easypub_desktop/desk/conversion/output_history_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

/// 内存中的转换历史：两条记录，第二条为中断事务；记录每次调用，不碰磁盘。
class _History implements OutputHistoryService {
  final calls = <String>[];
  final notifier = ChangeNotifier();
  bool recovered = false;
  late final List<OutputRecord> records = [
    OutputRecord(
      id: 't1',
      title: '山海之间',
      format: 'AZW3',
      path: r'D:\Books\输出\山海之间.azw3',
      directory: r'D:\Books\输出',
      status: '已完成',
      detail: '导出回执已保存。',
      verification: '',
      startedAt: DateTime(2026, 10, 10, 10, 42),
      restored: false,
      busy: false,
      terminal: true,
      interrupted: false,
      bytes: 3984588,
      sourcePreserved: true,
    ),
    OutputRecord(
      id: 't2',
      title: '雪夜行舟',
      format: 'KFX',
      path: r'D:\Books\输出\雪夜行舟.kfx',
      directory: r'D:\Books\输出',
      status: recovered ? '已完成' : '中断',
      detail: '暂存成品已核验，发布前中断。',
      verification: '',
      startedAt: DateTime(2026, 10, 10, 9, 15),
      restored: false,
      busy: false,
      terminal: true,
      interrupted: !recovered,
    ),
  ];
  @override
  Listenable get changes => notifier;
  @override
  String get status => '共 2 条记录';
  @override
  int get count => records.length;
  @override
  List<OutputRecord> page(int offset, {int limit = 50}) =>
      records.skip(offset).take(limit).toList();
  @override
  OutputRecord? find(String id) => records.where((r) => r.id == id).firstOrNull;
  @override
  Future<void> load() async => calls.add('load');
  @override
  Future<void> verify(String id) async => calls.add('verify:$id');
  @override
  Future<OutputPackageInspection> inspectPackage(String id) async {
    calls.add('inspect:$id');
    return const OutputPackageInspection(
      status: 'inspected',
      title: '山海之间',
      author: '林岚',
      language: 'zh',
      metadataStatus: 'matches',
      spineDocuments: 12,
      headingCount: 12,
      checkedLinks: 40,
      bodyBytes: 204800,
      imageReferences: 2,
      imageResources: 3,
    );
  }

  @override
  Future<OutputRecoveryPreview> previewRecovery(String id) async {
    calls.add('preview:$id');
    return OutputRecoveryPreview(
      id,
      r'D:\Books\输出\雪夜行舟.kfx',
      r'D:\Books\输出\.easypub-tx\t2',
      true,
    );
  }

  @override
  void cancelRecovery(OutputRecoveryPreview preview) =>
      calls.add('cancel:${preview.taskId}');
  @override
  Future<void> recover(OutputRecoveryPreview preview) async {
    calls.add('recover:${preview.taskId}');
    recovered = true;
  }
}

class _Desktop implements ConversionDesktop {
  final opened = <String>[];
  @override
  Future<String?> bundledConverter() async => null;
  @override
  Future<String?> chooseConverter() async => null;
  @override
  Future<void> openDirectory(String path) async => opened.add('dir:$path');
  @override
  Future<void> openOutput(String path) async => opened.add('file:$path');
}

void main() {
  for (final size in const [Size(1280, 800), Size(900, 640)]) {
    testWidgets('转换历史：列表、核验与事务恢复需确认 · $size', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = size;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final history = _History(), desktop = _Desktop();
      var back = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: OutputHistoryPage(
              history: history,
              desktop: desktop,
              onBack: () => back++,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('转换历史'), findsOneWidget);
      expect(find.text('山海之间 · AZW3'), findsOneWidget);
      expect(find.text('雪夜行舟 · KFX'), findsOneWidget);

      await t.tap(find.text('核验文件'));
      await t.pumpAndSettle();
      expect(history.calls, contains('verify:t1'));

      await t.tap(find.text('雪夜行舟 · KFX'));
      await t.pumpAndSettle();
      await t.tap(find.text('预览恢复'));
      await t.pumpAndSettle();
      expect(find.text('恢复输出事务'), findsOneWidget);
      // 取消不执行恢复，只释放预览。
      await t.tap(find.text('取消').last);
      await t.pumpAndSettle();
      expect(history.calls, isNot(contains('recover:t2')));
      expect(history.calls, contains('cancel:t2'));

      await t.tap(find.text('预览恢复'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认恢复'));
      await t.pumpAndSettle();
      expect(history.calls, contains('recover:t2'));

      await t.tap(find.text('所在文件夹'));
      await t.pumpAndSettle();
      expect(desktop.opened.single, startsWith('dir:'));
      await t.tap(find.text('返回本次任务'));
      expect(back, 1);
      expect(t.takeException(), isNull);
    });

    testWidgets('成品验收：核验结果分项显示，真机效果始终待验收 · $size', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = size;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final history = _History(), desktop = _Desktop();
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: OutputAcceptancePage(
              history: history,
              desktop: desktop,
              taskId: 't1',
              onBack: () {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(
        history.calls,
        containsAllInOrder(['load', 'verify:t1', 'inspect:t1']),
      );
      expect(find.text('成品验收'), findsOneWidget);
      expect(find.text('成品检查'), findsOneWidget);
      expect(find.text('章节与目录'), findsOneWidget);
      expect(find.text('字段一致'), findsOneWidget);
      expect(find.text('待验收'), findsOneWidget);
      await t.tap(find.text('打开成品'));
      await t.pumpAndSettle();
      expect(desktop.opened.single, startsWith('file:'));
      await t.tap(find.text('重新核验文件'));
      await t.pumpAndSettle();
      expect(history.calls.where((c) => c == 'verify:t1').length, 2);
      expect(t.takeException(), isNull);
    });
  }
}
