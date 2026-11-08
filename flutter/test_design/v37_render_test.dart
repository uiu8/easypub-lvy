// 用真实 Flutter 渲染管线输出 v37 预览图（不属于常规测试集，需单独运行）：
// flutter test test_design/v37_render_test.dart --update-goldens
import 'package:easypub_desktop/design_review_v37/grain.dart';
import 'package:easypub_desktop/design_review_v37/preview_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _out = '../../design/review-20261010-v37-flutter';

void main() {
  const dpr = 1.25; // 常见 Windows 125% 缩放
  final cases = <(String, V37Screen, V37Look, Size)>[
    ('chapters_1600x1000', V37Screen.chapters, V37Look.light, const Size(1600, 1000)),
    ('chapters_1280x800', V37Screen.chapters, V37Look.light, const Size(1280, 800)),
    ('chapters_1024x720_inspector', V37Screen.chaptersInspector, V37Look.light, const Size(1024, 720)),
    ('issues_1440x900', V37Screen.issues, V37Look.light, const Size(1440, 900)),
    ('issues_1024x720', V37Screen.issues, V37Look.light, const Size(1024, 720)),
    ('rules_1280x800', V37Screen.rules, V37Look.light, const Size(1280, 800)),
    ('chapters_1440x900', V37Screen.chapters, V37Look.light, const Size(1440, 900)),
    ('chapters_1280x800_dark', V37Screen.chapters, V37Look.dark, const Size(1280, 800)),
  ];
  for (final (name, screen, look, size) in cases) {
    testWidgets(name, (tester) async {
      final grain = await tester.runAsync(() async {
        await loadPreviewFonts();
        return makeGrainTile();
      });
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = size * dpr;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(V37Preview(screen: screen, look: look, grain: grain));
      await tester.pumpAndSettle();
      await expectLater(find.byType(V37Preview), matchesGoldenFile('$_out/$name.png'));
    });
  }
}
