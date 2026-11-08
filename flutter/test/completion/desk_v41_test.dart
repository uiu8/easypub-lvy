import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/tokens.dart';

/// V41：动效令牌（G-070）与界面数字等宽（G-069）。
void main() {
  test('动效令牌：五档时长与三条曲线', () {
    expect(
      [
        DeskMotion.fast,
        DeskMotion.snap,
        DeskMotion.base,
        DeskMotion.sheet,
        DeskMotion.slow,
      ].map((d) => d.inMilliseconds),
      [60, 120, 200, 300, 450],
    );
    expect(DeskMotion.easeOut, const Cubic(.165, .84, .44, 1));
    expect(DeskMotion.snapCurve, const Cubic(.32, .72, 0, 1));
    expect(DeskMotion.overshoot, const Cubic(.34, 1.3, .64, 1));
    // 回弹曲线会超过终点，平滑减速不会。
    expect(DeskMotion.overshoot.transform(.6), greaterThan(1));
    expect(DeskMotion.easeOut.transform(.6), lessThan(1));
  });

  test('界面黑体、宋体与等宽字体都用等宽数字', () {
    const tabular = [FontFeature.tabularFigures()];
    expect(ui(14).fontFeatures, tabular);
    expect(serif(14).fontFeatures, tabular);
    expect(mono(14).fontFeatures, tabular);
  });

  Widget app(Widget child, {bool reduced = false}) => MaterialApp(
    theme: deskTheme(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );

  double scaleOf(WidgetTester t) => t
      .widget<AnimatedScale>(
        find.ancestor(
          of: find.text('转换'),
          matching: find.byType(AnimatedScale),
        ),
      )
      .scale;

  testWidgets('按钮按下缩到 97%，松开带回弹复位；不可用的按钮不动', (t) async {
    var taps = 0;
    await t.pumpWidget(app(DeskButton('转换', onPressed: () => taps++)));
    final gesture = await t.startGesture(t.getCenter(find.text('转换')));
    await t.pump();
    expect(scaleOf(t), .97);
    final pressed = t.widget<AnimatedScale>(find.byType(AnimatedScale).first);
    expect(pressed.duration, DeskMotion.fast);
    await gesture.up();
    await t.pump();
    expect(scaleOf(t), 1);
    final released = t.widget<AnimatedScale>(find.byType(AnimatedScale).first);
    expect(released.duration, DeskMotion.snap);
    expect(released.curve, DeskMotion.overshoot);
    await t.pumpAndSettle();
    expect(taps, 1);

    await t.pumpWidget(app(const DeskButton('转换', onPressed: null)));
    final g2 = await t.startGesture(t.getCenter(find.text('转换')));
    await t.pump();
    expect(scaleOf(t), 1);
    await g2.up();
    expect(t.takeException(), isNull);
  });

  testWidgets('减少动效打开时，按钮的缩放时长为 0', (t) async {
    await t.pumpWidget(app(DeskButton('转换', onPressed: () {}), reduced: true));
    final gesture = await t.startGesture(t.getCenter(find.text('转换')));
    await t.pump();
    expect(
      t.widget<AnimatedScale>(find.byType(AnimatedScale).first).duration,
      Duration.zero,
    );
    await gesture.up();
    await t.pumpAndSettle();
  });
}
