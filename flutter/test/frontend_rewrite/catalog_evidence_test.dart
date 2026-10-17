import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/catalog_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/catalog/alignment_panel.dart';

void main() {
  testWidgets('changing selection discards late source evidence', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const first = CatalogAlignmentRow('本地甲', '参考甲', 1, '已对应');
    const second = CatalogAlignmentRow('本地乙', '参考乙', 3, '已对应');
    final a = Completer<String>();
    final b = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: CatalogAlignmentPanel(
            alignment: const CatalogAlignment([first, second], 2, 0, 0),
            onReturn: () {},
            onComposition: () {},
            onChoose: (_, _) {},
            readEvidence: (row) => identical(row, first) ? a.future : b.future,
          ),
        ),
      ),
    );
    await tester.tap(find.text('本地甲'));
    await tester.pump();
    await tester.tap(find.text('本地乙'));
    await tester.pump();
    b.complete('乙的原文');
    await tester.pumpAndSettle();
    expect(find.text('乙的原文'), findsOneWidget);
    a.complete('甲的迟到原文');
    await tester.pumpAndSettle();
    expect(find.text('甲的迟到原文'), findsNothing);
    expect(find.text('乙的原文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
