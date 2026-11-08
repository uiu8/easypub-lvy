import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/output_history_service.dart';
import 'package:easypub_desktop/application/change_history_service.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/conversion/output_history_page.dart';
import 'package:easypub_desktop/desk/history/tree_comparison.dart';

class History extends Fake implements OutputHistoryService {
  @override
  final ChangeNotifier changes = ChangeNotifier();
  @override
  int count = 51;
  bool fail = true;
  int recovered = 0, cancelled = 0;
  int loads = 0;
  @override
  String get status => '已读取历史';
  @override
  Future<void> load() async {
    loads++;
    if (fail) throw const FormatException('读取失败');
  }

  @override
  List<OutputRecord> page(int offset, {int limit = 50}) => List.generate(
    (count - offset).clamp(0, limit),
    (i) => OutputRecord(
      id: '${offset + i}',
      title: '历史 ${offset + i}',
      format: 'EPUB',
      path: 'D:/output/book.epub',
      directory: 'D:/output',
      status: '已中断',
      detail: '事务可恢复',
      verification: '',
      startedAt: DateTime(2026, 10, 2),
      restored: true,
      busy: false,
      terminal: true,
      interrupted: true,
    ),
  );
  @override
  Future<OutputRecoveryPreview> previewRecovery(String id) async =>
      OutputRecoveryPreview(
        id,
        'D:/output/${'很长的路径/' * 25}book.epub',
        'D:/transaction/${'嵌套目录/' * 25}',
        true,
      );
  @override
  Future<void> recover(OutputRecoveryPreview preview) async {
    recovered++;
  }

  @override
  void cancelRecovery(OutputRecoveryPreview preview) {
    cancelled++;
  }
}

class Desktop extends Fake implements ConversionDesktop {}

class Trees extends Fake implements ChangeHistoryService {
  Trees(this.title);
  final String title;
  @override
  Future<HistoryTrees> chapterTrees(
    ChangeDetail detail,
    int offset, {
    String? entryId,
  }) async => HistoryTrees(
    [HistoryTreeNode('one', title, 0, 'chapter')],
    [HistoryTreeNode('one', title, 0, 'volume')],
    1,
    1,
    0,
  );
}

void main() {
  testWidgets(
    'history failure stays visible, reload clamps pages, long recovery confirmation scrolls',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final history = History()..count = 0;
      addTearDown(history.changes.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: OutputHistoryPage(
              history: history,
              desktop: Desktop(),
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('无法读取转换历史，请重试。'), findsOneWidget);
      history
        ..fail = false
        ..count = 51;
      await tester.tap(find.text('刷新记录'));
      await tester.pumpAndSettle();
      expect(find.text('无法读取转换历史，请重试。'), findsNothing);
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(find.text('历史 50'), findsNWidgets(2));
      history.count = 1;
      await tester.tap(find.text('刷新记录'));
      await tester.pumpAndSettle();
      expect(find.text('历史 0'), findsNWidgets(2));
      expect(find.text('历史 50'), findsNothing);
      await tester.tap(find.text('预览恢复'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('取消'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(history.recovered, 0);
      expect(history.cancelled, 1);
      await tester.tap(find.text('预览恢复'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认恢复'));
      await tester.tap(find.text('确认恢复'));
      await tester.pumpAndSettle();
      expect(history.recovered, 1);
      expect(history.loads, greaterThanOrEqualTo(3));
      expect(history.cancelled, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'history tree highlights role-only changes and reloads a replaced service',
    (tester) async {
      final detail = ChangeDetail(
        const ChangeRecord(
          'one',
          'book',
          '章节',
          '分类',
          1,
          true,
          true,
          'chapters',
        ),
        [],
        'same',
      );
      Widget page(ChangeHistoryService history) => MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: HistoryTreeComparison(history: history, detail: detail),
        ),
      );
      await tester.pumpWidget(page(Trees('原服务')));
      await tester.pumpAndSettle();
      for (final text in tester.widgetList<Text>(find.text('原服务'))) {
        expect(text.style!.fontWeight, FontWeight.w600);
      }
      await tester.pumpWidget(page(Trees('新服务')));
      await tester.pumpAndSettle();
      expect(find.text('原服务'), findsNothing);
      expect(find.text('新服务'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
}
