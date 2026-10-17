import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/chapters/workspace_layout.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'workspace dividers respect body width and side panes survive responsive drawers',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey<DeskChapterLayoutState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: DeskChapterLayout(
              key: key,
              outline: const Column(
                children: [
                  Text('章节侧栏'),
                  TextField(key: ValueKey('tree-query')),
                ],
              ),
              reader: const SizedBox.expand(
                key: ValueKey('workspace-body'),
                child: Text('正文内容'),
              ),
              inspector: const Column(
                children: [
                  Text('属性侧栏'),
                  TextField(key: ValueKey('property-value')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('tree-query')), '保留搜索');
      await tester.enterText(
        find.byKey(const ValueKey('property-value')),
        '保留属性',
      );
      final width = tester
          .getSize(find.byKey(const ValueKey('workspace-body')))
          .width;
      await tester.drag(
        find.byKey(const ValueKey('chapter-tree-divider')),
        const Offset(90, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('workspace-body'))).width,
        lessThan(width),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('workspace-body'))).width,
        greaterThanOrEqualTo(420),
      );
      tester.view.physicalSize = const Size(820, 900);
      await tester.pumpAndSettle();
      expect(find.text('属性侧栏'), findsNothing);
      expect(find.text('章节侧栏'), findsOneWidget);
      key.currentState!.toggleInspector();
      await tester.pumpAndSettle();
      expect(find.text('保留属性'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭章节设置'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(600, 900);
      await tester.pumpAndSettle();
      expect(find.text('章节侧栏'), findsNothing);
      key.currentState!.toggleOutline();
      await tester.pumpAndSettle();
      expect(find.text('保留搜索'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭章节列表'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();
      expect(find.text('保留搜索'), findsOneWidget);
      expect(find.text('保留属性'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
