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
import 'package:easypub_desktop/desk/app/book_tabs.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/tokens.dart';

class NoPicker extends Fake implements BookFilePicker {}

/// V69：主题色（G-072）与书籍标签页（G-073）。
void main() {
  group('标签模型', () {
    test('打开、更新位置、上限 8 个时去掉最久没用的、关闭与相邻', () {
      final tabs = BookTabs();
      tabs.visit(Uri.parse('/books/a/checks'));
      tabs.visit(Uri.parse('/books/b/layout'));
      tabs.visit(Uri.parse('/books/a/chapters?node=1'));
      expect(tabs.tabs.map((t) => t.bookId), ['a', 'b']);
      expect(tabs.tabs.first.location, '/books/a/chapters?node=1');
      expect(tabs.active, 'a');
      tabs.visit(Uri.parse('/settings'));
      expect(tabs.active, isNull, reason: '非书页面不属于任何标签');
      expect(tabs.tabs.length, 2);

      for (final id in ['c', 'd', 'e', 'f', 'g', 'h']) {
        tabs.visit(Uri.parse('/books/$id/overview'));
      }
      expect(tabs.tabs.length, 8);
      tabs.visit(Uri.parse('/books/a/overview'));
      tabs.visit(Uri.parse('/books/i/overview'));
      expect(tabs.tabs.length, 8);
      expect(tabs.indexOf('b'), -1, reason: 'b 最久没用，被去掉');
      expect(tabs.indexOf('a'), isNonNegative);

      // 相邻（循环）。
      expect(tabs.neighbor(1), tabs.tabs.first.location);
      expect(tabs.neighbor(-1), tabs.tabs[tabs.tabs.length - 2].location);
      // 关闭当前标签：转到相邻标签；关闭非当前标签：不跳转。
      expect(tabs.close('c'), isNull);
      final next = tabs.close('i');
      expect(next, tabs.tabs.last.location);
      expect(tabs.active, isNull);
    });

    test('保存与恢复：只恢复书库里还在、地址合法的标签；移出书库的书自动去掉', () {
      final tabs = BookTabs()
        ..visit(Uri.parse('/books/a/checks?rule=check.number_gap'))
        ..visit(Uri.parse('/books/b/layout'));
      final saved = tabs.toJson();
      final again = BookTabs()
        ..restore(
          [
            ...saved,
            {'book': 'x', 'route': '/books/x/checks'},
            {'book': 'a', 'route': '/books/a/layout'},
            {'book': 'c', 'route': '/books/d/layout'},
            'junk',
          ],
          {'a', 'b', 'c'},
        );
      expect(again.toJson(), saved);
      again.retain({'b'});
      expect(again.tabs.map((t) => t.bookId), ['b']);
      expect((BookTabs()..restore(null, {'a'})).tabs, isEmpty);
    });
  });

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

  testWidgets('整机：两本书的标签切换、关闭、Ctrl+W、保存；设置里换主题色', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late LegacyLibraryAdapter library;
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
      library = LegacyLibraryAdapter(backend: state);
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
    expect(find.byKey(ValueKey(('book-tab', a))), findsOneWidget);

    router().go('/books/${Uri.encodeComponent(b)}/information');
    await settle();
    expect(find.byKey(ValueKey(('book-tab', a))), findsOneWidget);
    expect(find.byKey(ValueKey(('book-tab', b))), findsOneWidget);
    expect(find.textContaining('雾港来信'), findsWidgets);

    // 点 a 的标签：回到 a 最后停留的页面。
    await t.tap(find.byKey(ValueKey(('book-tab', a))));
    await settle();
    expect(path(), '/books/${Uri.encodeComponent(a)}/overview');
    expect(library.selection.value.current, a);

    // 保存：标签随工作区一起写入。
    final saved = library.readDraft('workspace/UI')!['tabs'] as List;
    expect(saved.map((e) => (e as Map)['book']), [a, b]);

    // 关闭当前标签 a：转到 b。
    await t.tap(find.byKey(ValueKey(('book-tab-close', a))));
    await settle();
    expect(path(), '/books/${Uri.encodeComponent(b)}/information');
    expect(find.byKey(ValueKey(('book-tab', a))), findsNothing);

    // Ctrl+W 关闭最后一个：回书库，标签条消失。
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyW);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle();
    expect(path(), '/');
    expect(find.byKey(const ValueKey('book-tab-new')), findsNothing);

    // 设置里换主题色：立即生效并保存。
    GoRouter.of(t.element(find.byType(Scaffold).first)).go('/settings');
    await settle();
    await t.ensureVisible(find.byKey(const ValueKey('settings-accent-teal')));
    await t.tap(find.byKey(const ValueKey('settings-accent-teal')));
    await settle();
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
