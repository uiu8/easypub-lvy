// 原生窗口底色跟随主题（用户反馈最大化时边缘闪黑）：标题栏把当前主题的画布色发给
// windows/runner 的 easypub/window 通道，窗口变大时新露出的区域用它填充，不再是黑色。
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/shell/title_bar.dart';
import 'package:easypub_desktop/desk/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('标题栏把主题画布色同步给原生窗口，换主题时再同步一次', (t) async {
    final calls = <Object?>[];
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    messenger.setMockMethodCallHandler(const MethodChannel('easypub/window'), (
      call,
    ) async {
      if (call.method == 'setBackground') calls.add(call.arguments);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('easypub/window'),
        null,
      );
    });
    Widget app(String mode) => MaterialApp(
      theme: deskTheme(mode: mode),
      home: const Scaffold(body: DeskTitleBar()),
    );
    await t.pumpWidget(app('paper'));
    await t.pump();
    expect(
      calls.last,
      deskTokens('paper', deskAccentOf(null)).canvas.toARGB32(),
    );
    final count = calls.length;
    // 重建但颜色没变：不重复发送。
    await t.pumpWidget(app('paper'));
    await t.pump();
    expect(calls.length, count);
    await t.pumpWidget(app('night'));
    // 主题切换有过渡动画，结束后是夜墨画布色。
    await t.pumpAndSettle();
    expect(
      calls.last,
      deskTokens('night', deskAccentOf(null)).canvas.toARGB32(),
    );
    await t.pumpWidget(const SizedBox());
  });
}
