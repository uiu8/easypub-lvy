import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/page_parts.dart';

void main() {
  testWidgets('可复制提示保留完整错误和路径，支持全选复制', (t) async {
    const message = '转换失败：无法读取输入文件。\nD:/样书目录/包含 空格的书籍.txt\n请检查文件后重新转换。';
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData')
          copied = (call.arguments as Map)['text'] as String;
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: const Scaffold(body: DeskInfoBar.selectable(message)),
      ),
    );
    await t.tap(find.byType(SelectableText));
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(copied, message);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'searchable anchored choice commits one value and Escape returns focus',
    (t) async {
      t.view.physicalSize = const Size(900, 720);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      var value = 0;
      var changes = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: StatefulBuilder(
                  builder: (context, update) => DeskChoice<int>(
                    key: const ValueKey('choice'),
                    value: value,
                    items: [
                      for (var i = 0; i < 200; i++)
                        DropdownMenuItem(value: i, child: Text('长篇预设 $i')),
                    ],
                    onChanged: (next) => update(() {
                      value = next!;
                      changes++;
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('choice')));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '199');
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(MenuItemButton, '长篇预设 199'));
      await t.pumpAndSettle();
      expect(value, 199);
      expect(changes, 1);
      await t.tap(find.byKey(const ValueKey('choice')));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      final trigger = t.widget<TextButton>(
        find.descendant(
          of: find.byKey(const ValueKey('choice')),
          matching: find.byType(TextButton),
        ),
      );
      expect(trigger.focusNode!.hasFocus, isTrue);
      expect(value, 199);
      expect(changes, 1);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('busy action suppresses submission and exposes the reason', (
    t,
  ) async {
    var submissions = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Center(
            child: DeskButton(
              '生成预览',
              busy: true,
              disabledReason: '正在生成',
              onPressed: () => submissions++,
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('生成预览'));
    await t.pump();
    expect(submissions, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('splitter adjusts by keyboard without disturbing pane text', (
    t,
  ) async {
    t.view.physicalSize = const Size(1000, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    const pane = ValueKey('leading-pane');
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: const Scaffold(
          body: DeskSplitView(
            leadingWidth: 300,
            leadingLabel: '列表',
            trailingLabel: '内容',
            leading: SizedBox(key: pane, child: Text('保留内容')),
            trailing: SizedBox(),
          ),
        ),
      ),
    );
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(t.getSize(find.byKey(pane)).width, 320);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pump();
    expect(t.getSize(find.byKey(pane)).width, 300);
    expect(find.text('保留内容'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
