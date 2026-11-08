// V103 银灰主题与主题色（SET-101、SET-102）：取用户截图里头发的灰。
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('银灰主题：设置值映射、令牌取头发的灰、默认用银灰强调，选了别的主题色照常替换', () {
    expect(deskThemes['silver'], '银灰');
    expect(deskThemeMode('silver', systemDark: true), 'silver');
    final silver = deskTokens('silver', deskAccentOf('ink'));
    expect(silver.dark, false);
    expect(silver.accent, const Color(0xFF706E74));
    expect(silver.lineStrong, const Color(0xFFC8C5C7));
    final teal = deskTokens('silver', deskAccentOf('teal'));
    expect(teal.accent, deskAccentOf('teal').accent);
    expect(teal.canvas, Desk.silver.canvas);
  });

  test('银灰主题色：宣纸与夜墨下都能选', () {
    final accent = deskAccentOf('silver');
    expect(accent.label, '银灰');
    expect(deskTokens('paper', accent).accent, const Color(0xFF706E74));
    expect(deskTokens('night', accent).dark, true);
  });

  testWidgets('银灰主题能构建界面', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(mode: 'silver'),
        home: Builder(
          builder: (context) => Text(
            'x',
            key: const ValueKey('probe'),
            style: TextStyle(color: context.desk.ink),
          ),
        ),
      ),
    );
    final text = t.widget<Text>(find.byKey(const ValueKey('probe')));
    expect(text.style?.color, Desk.silver.ink);
  });
}
