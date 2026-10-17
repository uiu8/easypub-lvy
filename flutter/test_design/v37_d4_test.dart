// D4 逐项预览出图（真实 Flutter 渲染）：
// flutter test test_design/v37_d4_test.dart --update-goldens
import 'package:easypub_desktop/design_review_v37/d4_library.dart';
import 'package:easypub_desktop/design_review_v37/d4_output.dart';
import 'package:easypub_desktop/design_review_v37/d4_settings.dart';
import 'package:easypub_desktop/design_review_v37/grain.dart';
import 'package:easypub_desktop/design_review_v37/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _out = '../../design/review-20261010-v37-flutter/d4';

void main() {
  const dpr = 1.25;
  const s = Size(1280, 800), b = Size(1600, 1000);
  final cases = <(String, Widget, Size)>[
    ('d4a_library_1280x800', const LibraryScreen(), s),
    ('d4a_library_compact_removed_1280x800', const LibraryScreen(compact: true, checked: 0, removed: true), s),
    ('d4a_library_drop_1280x800', const LibraryScreen(drop: true, checked: 0), s),
    ('d4b_library_states', const D4LibraryBoard(), b),
    ('d4c_overview_1280x800', const OverviewScreen(), s),
    ('d4c_source_project', const D4SourceProjectBoard(), b),
    ('d4d_folders_1280x800', const FoldersScreen(), s),
    ('d4d_folders_scanning_1280x800', const FoldersScreen(scanning: true), s),
    ('d4d_folders_states', const D4FoldersBoard(), b),
    ('d4e_mapping_1280x800', const MappingScreen(), s),
    ('d4e_mapping_diff_1280x800', const MappingScreen(diff: true), s),
    ('d4e_mapping_states', const D4MappingBoard(), b),
    ('d4f_conversion_1280x800', const ConversionScreen(), s),
    ('d4f_conversion_preflight_1280x800', const ConversionScreen(preflight: true), s),
    ('d4f_conversion_states', const D4ConversionBoard(), b),
    ('d4g_tasks_1280x800', const TasksScreen(), s),
    ('d4g_tasks_failed_1280x800', const TasksScreen(failedSelected: true), s),
    ('d4g_tasks_history', const D4TasksBoard(), b),
    ('d4h_acceptance_1280x800', const AcceptanceScreen(), s),
    for (var i = 0; i < settingsCategories.length; i++) ('d4i_settings_${i}_1280x800', SettingsScreen(category: i), s),
    ('d4i_settings_states', const D4SettingsBoard(), b),
  ];
  for (final (name, widget, size) in cases) {
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
            theme: deskTheme(Desk.light),
            home: Material(type: MaterialType.transparency, child: widget),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('$_out/$name.png'));
    });
  }
}
