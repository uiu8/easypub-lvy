import 'dart:async';
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

class ThemeSaveLibrary extends LegacyLibraryAdapter {
  ThemeSaveLibrary({required super.backend});

  final themeSaveGate = Completer<bool>();
  Future<bool>? themeSave;
  bool themeSaveCompleted = false;

  @override
  Future<bool> savePatch(Map<String, dynamic> patch) {
    if (!patch.containsKey('ui_accent')) return super.savePatch(patch);
    return themeSave = themeSaveGate.future
        .then<bool>((proceed) => proceed ? super.savePatch(patch) : false)
        .whenComplete(() => themeSaveCompleted = true);
  }
}

/// V69：主题色（G-072）。书籍标签页（G-073）已在 V71 删除，这里确认它不再出现。
void main() {
  test('主题色：只换强调色三件套；未知值回落墨灰', () {
    final teal = deskTheme(accent: 'teal');
    final desk = teal.extension<Desk>()!;
    final t = deskAccents.firstWhere((a) => a.id == 'teal');
    expect(desk.accent, t.accent);
    expect(desk.accentInk, t.onAccent);
    expect(desk.accentSoft, t.soft);
    expect(desk.pen, Desk.light.pen, reason: '语义色不变');
    expect(desk.canvas, Desk.light.canvas);
    expect(teal.colorScheme.primary, t.accent);
    expect(
      deskTheme(accent: 'nope').extension<Desk>()!.accent,
      Desk.light.accent,
    );
    expect(deskTheme().extension<Desk>()!.accent, Desk.light.accent);
    // 每种主题色在宣纸底上都有足够对比（文字与强调色互为前景）。
    double lum(Color c) {
      double ch(double v) => v <= .03928
          ? v / 12.92
          : math.pow((v + .055) / 1.055, 2.4).toDouble();
      return .2126 * ch(c.r) + .7152 * ch(c.g) + .0722 * ch(c.b);
    }

    double contrast(Color a, Color b) {
      final (x, y) = (lum(a), lum(b));
      return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
    }

    for (final a in deskAccents) {
      expect(contrast(a.accent, a.onAccent), greaterThan(4.5), reason: a.id);
      expect(
        contrast(a.accent, Desk.light.surface),
        greaterThan(4.5),
        reason: a.id,
      );
    }
  });

  testWidgets('整机：两本书之间切换没有标签条，Ctrl+W 不改页面，不保存标签；设置里换主题色', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late ThemeSaveLibrary library;
    late PrototypeState state;
    late String a, b;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final tmp = (await Directory('../artifacts').createTemp('v69-')).absolute;
      state = PrototypeState(settingsDirectory: '${tmp.path}/settings');
      library = ThemeSaveLibrary(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      for (final name in ['山海之间', '雾港来信']) {
        final f = File('${tmp.path}/$name.txt')
          ..writeAsStringSync('第一章 远行\n山路很长。\n第二章 归来\n海风很轻。\n');
        expect((await library.importFiles([f.path])).single.succeeded, true);
      }
      final books = library.books.value;
      a = books.firstWhere((x) => x.title == '山海之间').id;
      b = books.firstWhere((x) => x.title == '雾港来信').id;
    });
    addTearDown(() {
      if (!library.themeSaveGate.isCompleted)
        library.themeSaveGate.complete(false);
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
      RewriteApp(
        library: library,
        picker: NoPicker(),
        initialLocation: '/books/${Uri.encodeComponent(a)}/overview',
      ),
    );
    await settle();
    GoRouter router() => GoRouter.of(t.element(find.byType(Scaffold).first));
    String path() => router().routeInformationProvider.value.uri.path;
    expect(find.byKey(const ValueKey('book-tabs')), findsNothing);

    router().go('/books/${Uri.encodeComponent(b)}/information');
    await settle();
    expect(find.byKey(const ValueKey('book-tabs')), findsNothing);
    expect(find.byKey(ValueKey(('book-tab', a))), findsNothing);
    expect(library.selection.value.current, b);

    // 工作区只保存当前页面，不再有标签。
    final saved = library.readDraft('workspace/UI')!;
    expect(saved.containsKey('tabs'), false);
    expect(saved['route'], '/books/${Uri.encodeComponent(b)}/information');

    // Ctrl+W 不再关闭任何东西。
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyW);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle();
    expect(path(), '/books/${Uri.encodeComponent(b)}/information');

    // 设置里换主题色：立即生效并保存。
    GoRouter.of(t.element(find.byType(Scaffold).first)).go('/settings');
    await settle();
    await t.ensureVisible(find.byKey(const ValueKey('settings-accent-teal')));
    await t.tap(find.byKey(const ValueKey('settings-accent-teal')));
    await settle();
    // 固定 pump 时长不能证明备份/写盘完成。先明确保持保存未完成，
    // 再放行真实 adapter，并等它的 Future 完成后检查状态及主题。
    expect(library.themeSave, isNotNull, reason: '主题色点击必须发起保存');
    expect(library.themeSaveCompleted, isFalse);
    library.themeSaveGate.complete(true);
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!library.themeSaveCompleted && DateTime.now().isBefore(deadline)) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(library.themeSaveCompleted, isTrue, reason: '等待真实设置保存完成');
    expect(await t.runAsync(() => library.themeSave!), isTrue);
    await t.pumpAndSettle();
    expect(state.globalConfiguration['ui_accent'], 'teal');
    final themed = Theme.of(
      t.element(find.byKey(const ValueKey('settings-accent'))),
    );
    expect(
      themed.extension<Desk>()!.accent,
      deskAccents.firstWhere((x) => x.id == 'teal').accent,
    );
    expect(t.takeException(), isNull);
  });
}
