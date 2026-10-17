// D2 逐项预览出图（真实 Flutter 渲染）：
// flutter test test_design/v37_d2_test.dart --update-goldens
import 'package:easypub_desktop/design_review_v37/d2_catalog.dart';
import 'package:easypub_desktop/design_review_v37/d2_chapters.dart';
import 'package:easypub_desktop/design_review_v37/d2_checks.dart';
import 'package:easypub_desktop/design_review_v37/d2_history.dart';
import 'package:easypub_desktop/design_review_v37/issues.dart';
import 'package:easypub_desktop/design_review_v37/d2_repair.dart';
import 'package:easypub_desktop/design_review_v37/grain.dart';
import 'package:easypub_desktop/design_review_v37/rules.dart';
import 'package:easypub_desktop/design_review_v37/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _out = '../../design/review-20261010-v37-flutter/d2';

void main() {
  const dpr = 1.25;
  final cases = <(String, Widget, Size)>[
    ('d2a_commands', const D2CommandsBoard(), const Size(1600, 1000)),
    ('d2b_tree_body', const D2TreeBodyBoard(), const Size(1600, 1000)),
    ('d2b_narrow_tree_860x680', const D2NarrowTree(), const Size(860, 680)),
    ('d2c_edit_dialogs', const D2EditDialogsBoard(), const Size(1600, 1000)),
    ('d2d_target_dialogs', const D2TargetDialogsBoard(), const Size(1600, 1000)),
    ('d2e_preview', const D2PreviewBoard(), const Size(1600, 1000)),
    ('d2g_repair_plan_1280x800', const RepairScreen(), const Size(1280, 800)),
    ('d2g_repair_diff_1280x800', const RepairScreen(view: RepairView.diff), const Size(1280, 800)),
    ('d2g_repair_guided_1280x800', const RepairScreen(view: RepairView.guided), const Size(1280, 800)),
    ('d2g_repair_result_1280x800', const RepairScreen(view: RepairView.result), const Size(1280, 800)),
    ('d2h_repair_states', const D2RepairStatesBoard(), const Size(1600, 1000)),
    ('d2i_catalog_identity_1280x800', const CatalogScreen(), const Size(1280, 800)),
    ('d2i_catalog_source_1280x800', const CatalogScreen(view: CatalogView.source), const Size(1280, 800)),
    ('d2j_catalog_sources', const D2CatalogSourcesBoard(), const Size(1600, 1000)),
    ('d2k_catalog_alignment_1280x800', const CatalogScreen(view: CatalogView.alignment), const Size(1280, 800)),
    ('d2l_catalog_composition_1280x800', const CatalogScreen(view: CatalogView.composition), const Size(1280, 800)),
    ('d2m_checks_1280x800', const IssuesScreen(), const Size(1280, 800)),
    ('d2m_checks_states', const D2ChecksBoard(), const Size(1600, 1000)),
    ('d2n_compare_states', const D2CompareBoard(), const Size(1600, 1000)),
    ('d2o_history_1280x800', const HistoryScreen(), const Size(1280, 800)),
    ('d2o_history_confirm_1280x800', const HistoryScreen(confirm: true), const Size(1280, 800)),
    ('d2p_history_states', const D2HistoryBoard(), const Size(1600, 1000)),
    ('d2f_rules_book_1280x800', const RulesScreen(), const Size(1280, 800)),
    ('d2f_rules_detail_1280x800', const RulesScreen(view: RulesView.detail), const Size(1280, 800)),
    ('d2f_rules_import_default_1280x800', const RulesScreen(view: RulesView.importDefault), const Size(1280, 800)),
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
