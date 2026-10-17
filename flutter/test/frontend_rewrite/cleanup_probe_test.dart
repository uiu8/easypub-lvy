import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/cleanup_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/cleanup/rule_dialog.dart';

CleanupPreview result(String content) => CleanupPreview(
  '{}',
  'guard',
  content,
  0,
  1,
  0,
  [CleanupChange(2, 2, 0, '原文', content, 'literal_replace', false)],
  [],
);
void main() {
  testWidgets(
    'rule edits reject late samples and source changes hide obsolete evidence',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final first = Completer<CleanupPreview>(),
          second = Completer<CleanupPreview>();
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      var calls = 0, current = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: CleanupRuleDialog(
              initial: const {
                'kind': 'literal_replace',
                'find': '原文',
                'replace': '甲',
              },
              changes: changes,
              isCurrent: (_) => current,
              previewRule: (_) => calls++ == 0 ? first.future : second.future,
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('试算本书'));
      await tester.tap(find.text('试算本书'));
      await tester.pump();
      final replacement = find.byWidgetPredicate(
        (v) => v is TextField && v.decoration?.labelText == '替换为（可为空）',
      );
      await tester.ensureVisible(replacement);
      await tester.enterText(replacement, '乙');
      await tester.pump();
      await tester.ensureVisible(find.text('试算本书'));
      await tester.tap(find.text('试算本书'));
      await tester.pump();
      second.complete(result('新结果'));
      await tester.pumpAndSettle();
      expect(find.textContaining('新结果'), findsOneWidget);
      first.complete(result('迟到旧结果'));
      await tester.pumpAndSettle();
      expect(find.textContaining('迟到旧结果'), findsNothing);
      expect(find.textContaining('新结果'), findsOneWidget);
      current = false;
      changes.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('书稿已变化，试算结果过期，请重新试算。'), findsOneWidget);
      expect(find.textContaining('新结果'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('closing a pending rule probe discards its error', (
    tester,
  ) async {
    final pending = Completer<CleanupPreview>();
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: CleanupRuleDialog(
            previewRule: (_) => pending.future,
            isCurrent: (_) => true,
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('试算本书'));
    await tester.tap(find.text('试算本书'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.completeError(const FormatException('late'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
