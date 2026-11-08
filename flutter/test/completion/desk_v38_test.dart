import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/app_info.dart';
import 'package:easypub_desktop/application/parallel_books.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/settings/settings_page.dart';
import 'package:easypub_desktop/desk/widgets.dart';

/// V38：设置页“同时处理的书”（SET-069）。
void main() {
  testWidgets('成品与输出：同时处理的书默认自动，点选后保存，说明写明内存占用', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = (await Directory('../artifacts').createTemp('v38-settings-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: SettingsPage(
            settings: library,
            library: library,
            appInfo: () async => const AppInfo(packaged: false),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('成品与输出').first);
    await t.pumpAndSettle();
    final control = find.byKey(const ValueKey('settings-parallel_books'));
    await t.ensureVisible(control);
    await t.pumpAndSettle();
    DeskSegmented<String> segmented() => t.widget<DeskSegmented<String>>(
      find.descendant(
        of: control,
        matching: find.byType(DeskSegmented<String>),
      ),
    );
    expect(segmented().value, 'auto');
    expect(segmented().options, parallelBookChoices);
    final help = t
        .widget<DeskHelp>(find.byKey(const ValueKey('settings-help-同时处理的书')))
        .message;
    expect(help, contains('40–60 MB'));
    expect(help, contains('选 1 本与以前相同'));
    final note = t.widget<DeskText>(
      find.byKey(const ValueKey('settings-parallel-books-note')),
    );
    expect(note.text, contains('自动为 ${autoParallelBooks()} 本'));
    await t.tap(find.descendant(of: control, matching: find.text('4 本')));
    for (var i = 0; i < 200; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (state.globalConfiguration['parallel_books'] == '4') break;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(state.globalConfiguration['parallel_books'], '4');
    await t.pumpAndSettle();
    expect(segmented().value, '4');
    expect(t.takeException(), isNull);
  });
}
