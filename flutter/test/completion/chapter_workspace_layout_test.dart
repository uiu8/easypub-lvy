import 'package:flutter/gestures.dart';
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

  // V83：分隔条跟手。一帧内多个移动事件都要算进去；拖过上下限再拖回来，
  // 分隔条回到原位而不是漂走。
  Future<void> dragFrames(
    WidgetTester tester,
    Finder divider,
    List<List<double>> frames,
  ) async {
    final gesture = await tester.startGesture(
      tester.getCenter(divider),
      kind: PointerDeviceKind.mouse,
    );
    for (final moves in frames) {
      for (final dx in moves) {
        await gesture.moveBy(Offset(dx, 0));
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('chapter divider follows the pointer (V83)', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: const Scaffold(
          body: DeskChapterLayout(
            outline: SizedBox.expand(),
            reader: SizedBox.expand(),
            inspector: SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final key in ['chapter-tree-divider', 'chapter-property-divider']) {
      final divider = find.byKey(ValueKey(key));
      final sign = key == 'chapter-tree-divider' ? 1.0 : -1.0;
      final x = tester.getTopLeft(divider).dx;
      // 一帧五个 6px 的移动：分隔条要走满 30px。
      await dragFrames(tester, divider, [
        [for (var i = 0; i < 5; i++) 6 * sign],
      ]);
      expect(tester.getTopLeft(divider).dx, x + 30 * sign, reason: key);
      // 越过上限 300px 再拖回 300px：回到 +30 的位置。
      await dragFrames(tester, divider, [
        for (var i = 0; i < 10; i++) [30 * sign],
        for (var i = 0; i < 10; i++) [-30 * sign],
      ]);
      expect(tester.getTopLeft(divider).dx, x + 30 * sign, reason: key);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('split view divider follows the pointer (V83)', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: const Scaffold(
          body: DeskSplitView(
            leadingLabel: '左',
            trailingLabel: '右',
            leadingWidth: 400,
            leading: SizedBox.expand(key: ValueKey('split-leading')),
            trailing: SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final leading = find.byKey(const ValueKey('split-leading'));
    final divider = find.byTooltip('拖动调整；聚焦后用左右方向键');
    final width = tester.getSize(leading).width;
    await dragFrames(tester, divider, [
      [for (var i = 0; i < 5; i++) 8],
    ]);
    expect(tester.getSize(leading).width, width + 40);
    await dragFrames(tester, divider, [
      for (var i = 0; i < 10; i++) [-60],
      for (var i = 0; i < 10; i++) [60],
    ]);
    expect(tester.getSize(leading).width, width + 40);
    expect(tester.takeException(), isNull);
  });
}
