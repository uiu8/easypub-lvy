import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

/// V42：下拉菜单入场（G-071）。
void main() {
  Widget app(
    List<String> values,
    String value,
    ValueChanged<String?> onChanged, {
    bool reduced = false,
  }) => MaterialApp(
    theme: deskTheme(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(40),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 240,
                child: DeskChoice<String>(
                  value: value,
                  items: [
                    for (final v in values)
                      DropdownMenuItem(value: v, child: Text(v)),
                  ],
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  // 面板外层的 Opacity（_MenuEntrance 里唯一的一个）。
  Opacity panelOpacity(WidgetTester t) => t.widget<Opacity>(
    find
        .ancestor(
          of: find.byType(Material).last,
          matching: find.byType(Opacity),
        )
        .first,
  );

  testWidgets('打开时淡入并下滑，120 毫秒后完全显示；选择照常生效', (t) async {
    String? chosen;
    await t.pumpWidget(
      app(['EPUB', 'AZW3', 'MOBI', 'KFX'], 'AZW3', (v) => chosen = v),
    );
    await t.tap(find.text('AZW3'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 30));
    final mid = panelOpacity(t).opacity;
    expect(mid, greaterThan(0));
    expect(mid, lessThan(1));
    final shift = t.widget<Transform>(
      find
          .ancestor(of: find.text('MOBI'), matching: find.byType(Transform))
          .first,
    );
    expect(shift.transform.getTranslation().y, lessThan(0));
    await t.pump(const Duration(milliseconds: 120));
    expect(panelOpacity(t).opacity, 1);
    await t.tap(find.text('MOBI'));
    await t.pumpAndSettle();
    expect(chosen, 'MOBI');
    expect(find.text('EPUB'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('减少动效时菜单直接完整出现', (t) async {
    await t.pumpWidget(app(['EPUB', 'AZW3'], 'AZW3', (_) {}, reduced: true));
    await t.tap(find.text('AZW3'));
    await t.pump();
    expect(panelOpacity(t).opacity, 1);
  });

  testWidgets('长列表：面板不超过 420 高，可滚动选到最后一项', (t) async {
    t.view.physicalSize = const Size(900, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    String? chosen;
    final values = [for (var i = 1; i <= 30; i++) '选项 $i'];
    await t.pumpWidget(app(values, '选项 1', (v) => chosen = v));
    await t.tap(find.text('选项 1'));
    await t.pumpAndSettle();
    expect(find.text('搜索选项'), findsOneWidget);
    final panel = t.getSize(find.byType(Material).last);
    expect(panel.height, lessThanOrEqualTo(420));
    await t.scrollUntilVisible(
      find.text('选项 30'),
      100,
      scrollable: find
          .ancestor(of: find.text('选项 2'), matching: find.byType(Scrollable))
          .first,
    );
    await t.tap(find.text('选项 30'));
    await t.pumpAndSettle();
    expect(chosen, '选项 30');
    expect(t.takeException(), isNull);
  });
}
