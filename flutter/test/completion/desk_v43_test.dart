import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/app_info.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/settings/settings_page.dart';

/// V43：设置页开关统一靠右（SET-070）。
void main() {
  testWidgets('外观与交互、导入与收藏：每个开关的右边缘都对齐到同一位置', (t) async {
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
      final root = (await Directory('../artifacts').createTemp('v43-settings-'))
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
    for (final tab in ['外观与交互', '导入与收藏']) {
      await t.tap(find.text(tab).first);
      await t.pumpAndSettle();
      final rights = {
        for (final e in find.byType(Switch).evaluate())
          t.getTopRight(find.byWidget(e.widget)).dx.round(),
      };
      expect(
        find.byType(Switch).evaluate().length,
        greaterThan(1),
        reason: tab,
      );
      expect(rights.length, 1, reason: '$tab：开关右边缘 $rights');
    }
    expect(t.takeException(), isNull);
  });
}
