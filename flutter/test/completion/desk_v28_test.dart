import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/batch_field_dialog.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/widgets.dart';

/// V28：排版页书写方向、竖排中数字横排与注音/着重号写法说明（LAY-104–107）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  Future<void> until(WidgetTester t, bool Function() ready) async {
    for (var i = 0; i < 600; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (ready()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    fail('界面未就绪');
  }

  test('批量字段与变更说明使用中文名称和取值', () {
    expect(batchFieldLabels['writing_mode'], '书写方向');
    expect(batchFieldLabels['vertical_digits'], '竖排数字横排');
    expect(describeBatchValue('writing_mode', 'vertical'), '竖排');
    expect(describeBatchValue('writing_mode', 'horizontal'), '横排');
    expect(describeBatchValue('vertical_digits', 0), '不横排');
    expect(describeBatchValue('vertical_digits', 3), '3 位');
  });

  testWidgets('排版页：横排时数字位数不可改；切到竖排后可选位数并自动保存', (t) async {
    t.view.physicalSize = const Size(1500, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v28-layout-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')
        ..writeAsStringSync('第一章 开始\n子曰：｜学《xué》而时习之。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    expect(state.production.settings(id)['writing_mode'], 'horizontal');
    expect(state.production.settings(id)['vertical_digits'], 2);
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: LayoutPage(
            library: library,
            bookId: id,
            navigation: LayoutNavigationGuard(),
            pickPresetFile: () async => null,
            pickPresetDestination: () async => null,
            importCss: () async => null,
          ),
        ),
      ),
    );
    final mode = find.byKey(const ValueKey('layout-writing_mode'));
    await until(t, () => mode.evaluate().isNotEmpty);
    await t.ensureVisible(mode);
    await t.pump();
    final digits = find.byKey(const ValueKey('layout-vertical_digits'));
    Finder option(Finder parent, String text) =>
        find.descendant(of: parent, matching: find.text(text));
    expect(find.byKey(const ValueKey('layout-help-inline-markup')), findsOne);
    final help = t.widget<Tooltip>(
      find.descendant(
        of: find.byKey(const ValueKey('layout-help-inline-markup')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(help.message, contains('｜汉字《hàn zì》'));
    expect(help.message, contains('｜重点《・》'));

    // 横排：位数控件变灰，点击无效。
    DeskSegmented<int> segmented() => t.widget<DeskSegmented<int>>(
      find.descendant(of: digits, matching: find.byType(DeskSegmented<int>)),
    );
    expect(segmented().onChanged, isNull);
    await t.tap(option(digits, '3 位'));
    await t.pump();

    // 切到竖排并选 3 位，自动保存进书籍设置。
    await t.tap(option(mode, '竖排'));
    await t.pump();
    await t.tap(option(digits, '3 位'));
    await until(
      t,
      () =>
          state.production.settings(id)['writing_mode'] == 'vertical' &&
          state.production.settings(id)['vertical_digits'] == 3,
    );
    expect(segmented().onChanged, isNotNull);
  });

  testWidgets('排版页窄栏：书写方向与数字位数缩小显示、不溢出', (t) async {
    t.view.physicalSize = const Size(1100, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v28-narrow-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')..writeAsStringSync('第一章 开始\n正文。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: LayoutPage(
            library: library,
            bookId: state.currentId,
            navigation: LayoutNavigationGuard(),
            pickPresetFile: () async => null,
            pickPresetDestination: () async => null,
            importCss: () async => null,
          ),
        ),
      ),
    );
    final digits = find.byKey(const ValueKey('layout-vertical_digits'));
    await until(t, () => digits.evaluate().isNotEmpty);
    await t.ensureVisible(digits);
    await t.pump();
    expect(t.takeException(), isNull);
  });
}
