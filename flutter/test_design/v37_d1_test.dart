// D1 逐项预览出图（真实 Flutter 渲染）：
// flutter test test_design/v37_d1_test.dart --update-goldens
import 'package:easypub_desktop/design_review_v37/d1_global.dart';
import 'package:easypub_desktop/design_review_v37/grain.dart';
import 'package:easypub_desktop/design_review_v37/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _out = '../../design/review-20261010-v37-flutter/d1';

void main() {
  const dpr = 1.25;
  final cases = <(String, Widget, Size, Desk)>[
    ('d1_page_menu_1280x800', const D1PageMenu(), const Size(1280, 800), Desk.light),
    ('d1_book_picker_1280x800', const D1BookPicker(), const Size(1280, 800), Desk.light),
    ('d1_no_book_1280x800', const D1NoBook(), const Size(1280, 800), Desk.light),
    ('d1_no_book_1024x720', const D1NoBook(), const Size(1024, 720), Desk.light),
    ('d1_quick_layout_1280x800', const D1QuickLayout(), const Size(1280, 800), Desk.light),
    ('d1_command_palette_1280x800', const D1CommandPalette(), const Size(1280, 800), Desk.light),
    ('d1_board_window', const D1WindowBoard(), const Size(1600, 1000), Desk.light),
    ('d1_board_tray', const D1TrayBoard(), const Size(1600, 1000), Desk.light),
    ('d1_board_dialogs', const D1DialogBoard(), const Size(1600, 1000), Desk.light),
    ('d1_board_controls', const D1ControlsBoard(), const Size(1600, 1000), Desk.light),
    ('d1_page_menu_1280x800_dark', const D1PageMenu(), const Size(1280, 800), Desk.darkTheme),
  ];
  for (final (name, widget, size, desk) in cases) {
    testWidgets(name, (tester) async {
      final grain = await tester.runAsync(() async {
        await loadPreviewFonts();
        return makeGrainTile();
      });
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = size * dpr;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        GrainScope(
          tile: grain,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(desk),
            home: Material(type: MaterialType.transparency, child: widget),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('$_out/$name.png'));
    });
  }
}
