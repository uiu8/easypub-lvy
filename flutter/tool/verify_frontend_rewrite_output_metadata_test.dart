import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/output_history_service.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/desk/conversion/output_acceptance_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class History extends Fake implements OutputHistoryService {
  @override
  final ChangeNotifier changes = ChangeNotifier();
  OutputPackageInspection inspection = const OutputPackageInspection(
    status: 'inspected',
    title: '样书',
    author: '作者',
    language: 'en',
    metadataStatus: 'matches',
  );
  bool failVerify = false, missing = false;
  String verificationCode = 'matches';
  final pending = <String, Completer<OutputPackageInspection>>{};
  @override
  Future<void> load() async {}
  @override
  Future<void> verify(String id) async {
    if (failVerify) throw const FormatException('文件读取失败');
  }

  @override
  Future<OutputPackageInspection> inspectPackage(String id) async =>
      pending[id] == null ? inspection : await pending[id]!.future;
  @override
  OutputRecord? find(String id) => missing
      ? null
      : OutputRecord(
          id: id,
          title: '样书',
          format: 'EPUB',
          path: 'D:/output/book.epub',
          directory: 'D:/output',
          status: '已完成',
          detail: '',
          verification: '回执一致',
          verificationCode: verificationCode,
          startedAt: DateTime(2026),
          restored: false,
          busy: false,
          terminal: true,
          interrupted: false,
        );
}

class Desktop extends Fake implements ConversionDesktop {}

void main() {
  testWidgets(
    'acceptance distinguishes compared fields, mismatch and missing old snapshot',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final history = History();
      addTearDown(history.changes.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: OutputAcceptancePage(
              history: history,
              desktop: Desktop(),
              taskId: 'one',
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('字段一致'), findsOneWidget);
      history.inspection = const OutputPackageInspection(
        status: 'inspected',
        title: '样书',
        author: '作者',
        language: 'zh-CN',
        metadataStatus: 'mismatch',
        expectedMetadata: {'title': '样书', 'author': '作者', 'language': 'en'},
        metadataMismatches: ['language'],
      );
      await tester.tap(find.text('重新核验文件'));
      await tester.pumpAndSettle();
      expect(find.text('不一致'), findsOneWidget);
      expect(find.textContaining('语言：预期“en”，实际“zh-CN”'), findsOneWidget);
      expect(find.text('字段一致'), findsNothing);
      history.inspection = const OutputPackageInspection(
        status: 'inspected',
        title: '旧成品',
      );
      await tester.tap(find.text('重新核验文件'));
      await tester.pumpAndSettle();
      expect(find.text('待对照'), findsOneWidget);
      expect(find.textContaining('此回执缺少预期快照'), findsOneWidget);
      expect(find.text('字段一致'), findsNothing);
      history.inspection = const OutputPackageInspection(
        status: 'kindle_container_checked',
        detail: 'KF8 容器检查通过；内容待核验。',
      );
      await tester.tap(find.text('重新核验文件'));
      await tester.pumpAndSettle();
      expect(find.text('Kindle 容器'), findsOneWidget);
      // Chapters, metadata, body and resource position remain unverified after container checks.
      expect(find.text('待核验'), findsAtLeastNWidgets(4));
      expect(find.text('通过'), findsAtLeastNWidgets(1));
      expect(find.text('字段一致'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'late inspection cannot overwrite another task; failed verification cannot reuse cached pass',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final history = History();
      addTearDown(history.changes.dispose);
      history.pending['one'] = Completer<OutputPackageInspection>();
      history.pending['two'] = Completer<OutputPackageInspection>();
      var returned = false;
      Widget page(String id) => MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: OutputAcceptancePage(
            history: history,
            desktop: Desktop(),
            taskId: id,
            onBack: () => returned = true,
          ),
        ),
      );
      await tester.pumpWidget(page('one'));
      await tester.pump();
      await tester.pumpWidget(page('two'));
      await tester.pump();
      history.pending['two']!.complete(
        const OutputPackageInspection(
          status: 'inspected',
          title: '新任务成品',
          metadataStatus: 'matches',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('新任务成品'), findsOneWidget);
      history.pending['one']!.complete(
        const OutputPackageInspection(
          status: 'inspected',
          title: '旧任务成品',
          metadataStatus: 'mismatch',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('旧任务成品'), findsNothing);
      expect(find.textContaining('新任务成品'), findsOneWidget);
      history.failVerify = true;
      await tester.pumpWidget(
        KeyedSubtree(
          key: const ValueKey('failed-inspection'),
          child: page('two'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('字段一致'), findsNothing);
      expect(find.text('字段一致'), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == '核验尚未完成'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('文件读取失败'));
      expect(find.text('文件读取失败'), findsOneWidget);
      history.failVerify = false;
      history.verificationCode = 'changed';
      history.pending.clear();
      history.inspection = const OutputPackageInspection(
        status: 'failed',
        detail: '哈希不一致',
      );
      await tester.pumpWidget(
        KeyedSubtree(
          key: const ValueKey('changed-inspection'),
          child: page('two'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is Icon && w.semanticLabel == '成品核验存在问题',
        ),
        findsOneWidget,
      );
      expect(find.text('字段一致'), findsNothing);
      expect(tester.takeException(), isNull);
      history.missing = true;
      await tester.pumpWidget(page('missing'));
      await tester.pumpAndSettle();
      expect(find.text('找不到对应的成品记录。'), findsOneWidget);
      expect(find.text('重新核验文件'), findsOneWidget);
      await tester.tap(find.text('返回转换任务'));
      expect(returned, isTrue);
    },
  );
}
