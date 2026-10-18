import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:go_router/go_router.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/tokens.dart';

class NoPicker extends Fake implements BookFilePicker {}

double lum(Color c) {
  double ch(double v) =>
      v <= .03928 ? v / 12.92 : math.pow((v + .055) / 1.055, 2.4).toDouble();
  return .2126 * ch(c.r) + .7152 * ch(c.g) + .0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final (x, y) = (lum(a), lum(b));
  return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
}

/// V79：多种主题（SET-074）。
void main() {
  test('三种主题、六种主题色的令牌与对比度；设置值换算', () {
    for (final mode in ['paper', 'night', 'contrast']) {
      for (final a in deskAccents) {
        final d = deskTokens(mode, a);
        final reason = '$mode ${a.id}';
        expect(d.dark, mode == 'night', reason: reason);
        expect(
          contrast(d.accentInk, d.accent),
          greaterThan(4.5),
          reason: reason,
        );
        expect(contrast(d.ink, d.surface), greaterThan(7), reason: reason);
        expect(contrast(d.ink2, d.surface), greaterThan(4.5), reason: reason);
        expect(contrast(d.accent, d.surface), greaterThan(3), reason: reason);
        final theme = deskTheme(accent: a.id, mode: mode);
        expect(theme.extension<Desk>()!.accent, d.accent);
        expect(theme.extension<Desk>()!.canvas, d.canvas);
        expect(
          theme.brightness,
          mode == 'night' ? Brightness.dark : Brightness.light,
        );
      }
    }
    // 高对比固定黑色强调，不随主题色。
    expect(
      deskTokens('contrast', deskAccents[1]).accent,
      const Color(0xFF000000),
    );
    expect(contrast(Desk.contrast.ink, Desk.contrast.surface), greaterThan(20));
    // 宣纸与改动前相同。
    final paper = deskTokens('paper', deskAccents.first);
    expect(paper.canvas, Desk.light.canvas);
    expect(paper.ink, Desk.light.ink);
    expect(paper.accent, Desk.light.accent);
    expect(deskThemeMode('system', systemDark: true), 'night');
    expect(deskThemeMode('system', systemDark: false), 'paper');
    expect(deskThemeMode('contrast', systemDark: true), 'contrast');
    expect(deskThemeMode(null, systemDark: true), 'paper');
    expect(deskThemeMode('nope', systemDark: false), 'paper');
    expect(deskThemes.keys, ['paper', 'night', 'contrast', 'system']);
  });

  testWidgets('设置里换主题立即生效并保存；跟随系统时随系统深浅色切换', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    late LegacyLibraryAdapter library;
    late PrototypeState state;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final tmp = (await Directory('../artifacts').createTemp('v79-')).absolute;
      state = PrototypeState(settingsDirectory: '${tmp.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> settle() async {
      for (var i = 0; i < 60; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
      }
    }

    await t.pumpWidget(
      RewriteApp(library: library, picker: NoPicker(), initialLocation: '/'),
    );
    await settle();
    Desk desk() =>
        Theme.of(t.element(find.byType(Scaffold).first)).extension<Desk>()!;
    expect(desk().dark, false);
    GoRouter.of(t.element(find.byType(Scaffold).first)).go('/settings');
    await settle();
    final seg = find.byKey(const ValueKey('settings-theme'));
    await t.tap(find.descendant(of: seg, matching: find.text('夜墨')));
    await settle();
    expect(state.globalConfiguration['ui_theme'], 'night');
    expect(desk().dark, true);
    await t.tap(find.descendant(of: seg, matching: find.text('高对比')));
    await settle();
    expect(desk(), Desk.contrast);
    expect(find.text('主题色（高对比固定黑色）'), findsOneWidget);
    await t.tap(find.descendant(of: seg, matching: find.text('跟随系统')));
    await settle();
    expect(state.globalConfiguration['ui_theme'], 'system');
    expect(desk().dark, false);
    t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await settle();
    expect(desk().dark, true, reason: '系统改为深色后切到夜墨');
    t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await settle();
    expect(desk().dark, false);
    expect(t.takeException(), isNull);
  });
}
