import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/catalog/paste_field.dart';
import 'package:easypub_desktop/desk/catalog/source_dialog.dart';

import 'catalog_search_test.dart' show SearchCatalog;

void main() {
  testWidgets(
    'long paste retains all text, edits only visible slice and undoes whole paste',
    (t) async {
      final full = TextEditingController();
      addTearDown(full.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 650,
              child: CatalogPasteField(
                controller: full,
                enabled: true,
                onChanged: () {},
              ),
            ),
          ),
        ),
      );
      final original = List.generate(
        30000,
        (i) => '第${i + 1}章 标题${i + 1}',
      ).join('\n');
      final field = find.byType(TextField);
      String visible() => t.widget<TextField>(field).controller!.text;
      Future<void> undo(bool redo) async {
        await t.tap(field);
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        if (redo) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
        if (redo) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await t.pump();
      }

      await t.enterText(field, original);
      await t.pump();
      expect(full.text, original);
      expect(visible().length, lessThanOrEqualTo(4096));
      await undo(false);
      expect(full.text, isEmpty);
      await undo(true);
      expect(full.text, original);
      final first = visible();
      await t.tap(find.text('下一段'));
      await t.pump();
      final second = visible();
      expect(second, isNot(first));
      final edited = second.replaceFirst('标题', '修订');
      await t.enterText(field, edited);
      await t.pump();
      expect(
        full.text,
        original.replaceRange(
          first.length,
          first.length + second.length,
          edited,
        ),
      );
      await undo(false);
      expect(full.text, original);
      await undo(true);
      expect(full.text, contains('修订'));
      await t.tap(find.text('清空目录'));
      await t.pump();
      expect(full.text, isEmpty);
      await undo(false);
      expect(full.text, contains('修订'));
      expect(full.text, endsWith('第30000章 标题30000'));
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('dialog acquires entire long input and source switch clears it', (
    t,
  ) async {
    t.view.physicalSize = const Size(1400, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final session = SearchCatalog();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CatalogSourceDialog(
            session: session,
            pickFile: () async => null,
          ),
        ),
      ),
    );
    await t.tap(find.text('粘贴目录'));
    await t.pump();
    final input = List.generate(
      30000,
      (i) => '第${i + 1}章 标题${i + 1}',
    ).join('\n');
    await t.enterText(find.byType(TextField).first, input);
    await t.pump();
    await t.tap(find.text('获取目录'));
    await t.pumpAndSettle();
    expect(session.acquired, input);
    await t.tap(find.text('在线目录'));
    await t.pump();
    await t.tap(find.text('粘贴目录'));
    await t.pump();
    expect(
      t.widget<TextField>(find.byType(TextField).first).controller!.text,
      isEmpty,
    );
    expect(find.text('下一段'), findsNothing);
  });
}
