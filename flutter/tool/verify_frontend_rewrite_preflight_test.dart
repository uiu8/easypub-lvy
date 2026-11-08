import 'package:easypub_desktop/prototype/conversion_preflight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/conversion/preflight_panel.dart';

void main() {
  test(
    'group severity preserves every book finding and persisted category',
    () {
      final checks = ConversionPreview(
        const [
          ConversionFinding(
            'one',
            '编号提醒',
            'warning',
            '需要审阅',
            'chapters',
            category: 'chapters',
          ),
          ConversionFinding(
            'two',
            '章节失败',
            'blocking',
            '需要处理',
            'chapters',
            category: 'chapters',
          ),
          ConversionFinding(
            'one',
            '输出预览通过',
            'pass',
            'D:/output/one.epub',
            null,
            category: 'destination',
          ),
        ],
        const [],
        previewed: false,
        bookTitles: const {'one': '长河照影', 'two': '山海来信'},
      );
      expect(checks.bookTitle('two'), '山海来信');
      final group = checks.groups.firstWhere((g) => g.key == 'chapters');
      expect(group.title, '章节与目录');
      expect(group.items.map((f) => f.bookId), ['one', 'two']);
      expect(group.level, 'blocking');
      expect(checks.needsAcknowledgement, true);
      expect(checks.blocked, true);
      const stored = ConversionPreflightIssue(
        level: ConversionPreflightLevel.warning,
        title: '提醒',
        detail: '详情',
        category: 'cleanup',
        isCoverIssue: true,
      );
      expect(
        ConversionPreflightIssue.fromJson(stored.toJson()).category,
        'cleanup',
      );
      expect(
        ConversionPreflightIssue.fromJson(stored.toJson()).isCoverIssue,
        isTrue,
      );
      expect(
        ConversionPreflightIssue.fromJson({'level': 'blocking'}).isCoverIssue,
        isFalse,
      );
      expect(
        ConversionPreflightIssue.fromJson({'level': 'pass', 'title': '旧记录'})
            .category,
        'general',
      );
    },
  );
  final plan = ConversionPreview(
    const [
      ConversionFinding('book', '源文件与版本', 'pass', '原稿可读', null),
      ConversionFinding('book', '章节编号跳跃', 'warning', '编号跳跃不等于正文缺失', 'chapters'),
    ],
    const [ConversionOutput('book', '长河照影', 'D:/output/book.epub', '已预览')],
    previewed: true,
  );
  testWidgets(
    'checks expose actual details and repair destination; stale confirmation disabled',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? repaired;
      Widget page(bool current) => MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: PreflightPanel(
            plan: plan,
            current: current,
            onBack: () {},
            openRepair: (id, page) => repaired = '$id/$page',
          ),
        ),
      );
      await tester.pumpWidget(page(true));
      expect(find.text('编号跳跃不等于正文缺失'), findsOneWidget);
      await tester.tap(find.text('查看 1 项提醒'));
      await tester.pump();
      expect(find.text('源文件与版本'), findsNothing);
      await tester.tap(find.text('章节编号跳跃').first);
      await tester.pump();
      expect(find.text('编号跳跃不等于正文缺失'), findsOneWidget);
      await tester.tap(find.text('前往处理'));
      expect(repaired, 'book/chapters');
      expect(find.text('可保留并转换'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.pumpWidget(page(false));
      expect(find.text('检查结果已失效'), findsOneWidget);
      expect(find.text('需要重新生成输出计划'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // A short desktop viewport must keep footer commands reachable while
      // the complete evidence and warning controls remain scrollable.
      tester.view.physicalSize = const Size(1100, 480);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.text('返回设置')).bottom, lessThanOrEqualTo(480));
      await tester.ensureVisible(find.text('查看全部检查'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看全部检查'));
      await tester.pumpAndSettle();
      expect(find.text('查看 1 项提醒'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'blocked dialog has no commit and offers repair then fresh check',
    (tester) async {
      final blocked = ConversionPreview(
        [
          ...plan.findings,
          const ConversionFinding(
            'book',
            '封面文件不可访问',
            'blocking',
            'cover.jpg',
            'metadata',
          ),
        ],
        plan.outputs,
        previewed: false,
      );
      bool? result;
      String? repaired;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => PreflightBlockedDialog(
                      plan: blocked,
                      openRepair: (id, page) => repaired = '$id/$page',
                    ),
                  );
                },
                child: const Text('检查'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('检查'));
      await tester.pumpAndSettle();
      expect(find.text('有 1 个问题阻止转换'), findsOneWidget);
      expect(find.text('确认转换'), findsNothing);
      expect(
        tester.getTopLeft(find.text('封面文件不可访问')).dy,
        lessThan(tester.getTopLeft(find.text('章节编号跳跃')).dy),
      );
      await tester.tap(
        find.byKey(const ValueKey('blocked-repair-book-封面文件不可访问')),
      );
      expect(repaired, 'book/metadata');
      tester.view.physicalSize = const Size(700, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('重新检查'));
      await tester.tap(find.text('重新检查'));
      await tester.pumpAndSettle();
      expect(result, true);
      expect(tester.takeException(), isNull);
    },
  );
}
