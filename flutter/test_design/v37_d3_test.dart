// D3 逐项预览出图（真实 Flutter 渲染）：
// flutter test test_design/v37_d3_test.dart --update-goldens
import 'package:easypub_desktop/design_review_v37/d3_cleanup.dart';
import 'package:easypub_desktop/design_review_v37/d3_layout.dart';
import 'package:easypub_desktop/design_review_v37/d3_meta.dart';
import 'package:easypub_desktop/design_review_v37/d3_resources.dart';
import 'package:easypub_desktop/design_review_v37/grain.dart';
import 'package:easypub_desktop/design_review_v37/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _out = '../../design/review-20261010-v37-flutter/d3';

void main() {
  const dpr = 1.25;
  const s = Size(1280, 800), b = Size(1600, 1000);
  final cases = <(String, Widget, Size)>[
    ('d3a_meta_1280x800', const MetaScreen(), s),
    ('d3a_meta_pending_1280x800', const MetaScreen(state: 2), s),
    ('d3b_cover_crop_1280x800', const CoverCropScreen(), s),
    ('d3b_cover_original_1280x800', const CoverCropScreen(original: true), s),
    ('d3c_text_cover_1280x800', const TextCoverScreen(), s),
    ('d3c_cover_states', const D3CoverBoard(), b),
    ('d3d_layout_1280x800', const LayoutScreen(), s),
    ('d3d_layout_incomplete_1280x800', const LayoutScreen(incomplete: true), s),
    ('d3e_presets_project_1280x800', const LayoutPresetsScreen(), s),
    ('d3e_presets_global_1280x800', const LayoutPresetsScreen(source: 1), s),
    ('d3e_presets_preview_1280x800', const LayoutPresetsScreen(preview: true), s),
    ('d3f_layout_states', const D3LayoutBoard(), b),
    ('d3g_layout_batch', const D3BatchBoard(), b),
    ('d3g_global_layout_1280x800', const GlobalLayoutScreen(), s),
    ('d3h_cleanup_1280x800', const CleanupScreen(), s),
    ('d3h_cleanup_steps_1280x800', const CleanupScreen(view: CleanupView.steps), s),
    ('d3h_cleanup_candidates_1280x800', const CleanupScreen(view: CleanupView.candidates), s),
    ('d3i_cleanup_diff_1280x800', const CleanupScreen(view: CleanupView.diff), s),
    ('d3i_cleanup_result_1280x800', const CleanupScreen(view: CleanupView.result), s),
    ('d3j_cleanup_rule_1280x800', const CleanupRuleScreen(), s),
    ('d3k_cleanup_states', const D3CleanupBoard(), b),
    ('d3l_cleanup_batch', const D3CleanupBatchBoard(), b),
    ('d3m_resources_1280x800', const ResourcesScreen(), s),
    ('d3m_resource_edit_1280x800', const ResourceEditScreen(), s),
    ('d3m_resource_preview_1280x800', const ResourceEditScreen(preview: true), s),
    ('d3n_resources_states', const D3ResourcesBoard(), b),
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
