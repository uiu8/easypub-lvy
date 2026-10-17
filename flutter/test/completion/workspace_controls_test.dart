import 'package:easypub_desktop/desk/controls/controls.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/conversion/conversion_page.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

import 'library_removal_test.dart' as setup;

class _Desktop extends Fake
    implements ConversionDesktop, OutputDirectoryDesktop, KfxConversionDesktop {
  @override
  Future<String> defaultOutputDirectory() async => 'D:/software/test-output';
  @override
  Future<String?> bundledConverter() async => 'D:/software/test/kindling.exe';
  @override
  Future<String?> bundledKfxConverter() async => 'D:/software/test/bokai.exe';
}

class _Session extends Fake implements ConversionSession {
  @override
  final ChangeNotifier changes = ChangeNotifier();
  @override
  bool get busy => false;
  @override
  ConversionRequest? request;
  @override
  List<ConversionOutput> get outputs => [];
  @override
  Future<ConversionPreview> preview(ConversionRequest value) async {
    request = value;
    return ConversionPreview(
      [
        ConversionFinding(
          value.books.first,
          '已记录本次设置',
          'blocking',
          '此探针只检查准备请求，不写出文件。',
          null,
        ),
      ],
      [],
      previewed: false,
    );
  }

  @override
  bool isCurrent(ConversionPreview preview) => true;
  @override
  void dispose() => changes.dispose();
}

class _Library extends LegacyLibraryAdapter {
  _Library(PrototypeState state) : super(backend: state);
  final session = _Session();
  @override
  ConversionSession openConversion() => session;
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  void window(WidgetTester t) {
    t.view.physicalSize = const Size(980, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    const channel = MethodChannel('window_manager');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
  }

  Future<void> until(WidgetTester t, bool Function() complete) async {
    for (var i = 0; i < 150 && !complete(); i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await t.pump();
  }

  testWidgets(
    '130% empty tools and global presets work before choosing a book',
    (t) async {
      window(t);
      t.platformDispatcher.textScaleFactorTestValue = 1.15;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      t.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final root = await t.runAsync(
        () async =>
            (await Directory('../artifacts').createTemp('empty-tools-'))
                .absolute,
      );
      final state = PrototypeState(settingsDirectory: '${root!.path}/settings');
      final library = _Library(state);
      expect(await t.runAsync(library.load), true);
      expect(await t.runAsync(library.initializeWorkspace), true);
      await t.runAsync(() async {
        expect(
          await library.savePatch({
            'ui_scale': 1.3,
            'ui_density': 'compact',
            'layout_presets': [
              {
                'name': '通用小说',
                'values': {'font_size': 20.0},
              },
            ],
          }),
          true,
          reason: library.snapshot.value.status,
        );
      });
      await t.pumpWidget(
        RewriteApp(
          library: library,
          picker: setup.NoPicker(),
          conversionDesktop: _Desktop(),
          initialLocation: '/tools/overview',
        ),
      );
      await settle(t);
      final shellContext = t.element(
        find.byKey(const ValueKey('workspace-output-bar')),
      );
      expect(
        MediaQuery.textScalerOf(shellContext).scale(10),
        closeTo(14.95, .01),
      );
      expect(Theme.of(shellContext).visualDensity, VisualDensity.compact);
      expect(MediaQuery.of(shellContext).disableAnimations, true);
      for (final label in [
        '概览',
        '检查与修复',
        '章节',
        '书籍信息',
        '排版',
        '文本清理',
        '图片与资源',
      ]) {
        final nav = find.byTooltip(label).first;
        await t.ensureVisible(nav);
        await t.tap(nav);
        await settle(t);
        if (label == '排版') {
          expect(find.text('通用排版预设'), findsOneWidget);
          await t.tap(find.text('全局默认').first);
          await t.pumpAndSettle();
          await t.tap(find.text('通用小说'));
          await t.pumpAndSettle();
          await t.tap(find.text('重命名'));
          await t.pumpAndSettle();
          await t.enterText(find.byType(TextFormField), '长篇小说');
          await t.tap(find.text('保存'));
          await until(
            t,
            () =>
                (library.snapshot.value.configuration['layout_presets'] as List)
                    .single['name'] ==
                '长篇小说',
          );
          await t.pump(const Duration(milliseconds: 300));
          expect(find.text('长篇小说'), findsOneWidget);
        } else {
          expect(find.text('选择一本书，开始使用这个工具'), findsOneWidget, reason: label);
        }
        expect(
          find.byKey(const ValueKey('workspace-book-picker')),
          findsOneWidget,
        );
        expect(t.takeException(), isNull, reason: label);
        final outputBar = t.getRect(
          find.byKey(const ValueKey('workspace-output-bar')),
        );
        expect(outputBar.bottom, lessThanOrEqualTo(720));
        expect(outputBar.height, lessThan(80));
      }
      expect(library.books.value, isEmpty);
      expect(library.selection.value.selected, isEmpty);
      final router = GoRouter.of(
        t.element(find.byKey(const ValueKey('workspace-output-bar'))),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      for (final shortcut in {
        LogicalKeyboardKey.digit3: '/tools/chapters',
        LogicalKeyboardKey.digit4: '/tools/checks',
        LogicalKeyboardKey.digit5: '/conversion',
        LogicalKeyboardKey.digit6: '/tasks',
        LogicalKeyboardKey.digit2: '/folders',
        LogicalKeyboardKey.digit1: '/',
      }.entries) {
        await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await t.sendKeyEvent(shortcut.key);
        await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await settle(t);
        expect(router.routeInformationProvider.value.uri.path, shortcut.value);
      }
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyF);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      final search = find.descendant(
        of: find.byType(LibraryPage),
        matching: find.byType(TextField),
      );
      expect(t.widget<TextField>(search).focusNode!.hasFocus, true);
      await t.enterText(search, '键盘搜索');
      expect(t.widget<TextField>(search).controller!.text, '键盘搜索');
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyA);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(
        t.widget<TextField>(search).controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 4),
      );
      await t.pump(const Duration(milliseconds: 600));
      await t.enterText(search, '改过的搜索');
      await t.pump(const Duration(milliseconds: 600));
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(t.widget<TextField>(search).controller!.text, '键盘搜索');
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(t.widget<TextField>(search).controller!.text, '改过的搜索');
      expect(router.routeInformationProvider.value.uri.path, '/');
      expect(t.takeException(), isNull);
      bool? saved;
      library.flushWorkspace().then((value) => saved = value);
      await until(t, () => saved != null);
      expect(saved, true, reason: library.workspaceSave.value.message);
      await t.pumpWidget(const SizedBox.shrink());
      var storageClosed = false;
      library.closeWorkspaceStorage().then((_) => storageClosed = true);
      await until(t, () => storageClosed);
      expect(storageClosed, true);
      library.dispose();
      state.dispose();
      final reopened = PrototypeState(
        settingsDirectory: '${root.path}/settings',
      );
      final restored = LegacyLibraryAdapter(backend: reopened);
      await t.runAsync(restored.load);
      expect(
        (restored.snapshot.value.configuration['layout_presets'] as List)
            .single['name'],
        '长篇小说',
      );
      restored.dispose();
      reopened.dispose();
    },
  );
  testWidgets(
    'book selector preserves tool and batch selection; footer and quick conversion share KFX request',
    (t) async {
      window(t);
      final fixture = await t.runAsync(setup.fixture);
      final (state, initial, _) = fixture!;
      initial.dispose();
      final library = _Library(state);
      await t.runAsync(library.initializeWorkspace);
      await t.runAsync(() => library.savePatch({'ui_scale': 1.3}));
      final books = library.books.value;
      library.selectBook(books.first.id);
      library.checkBooks(books.map((b) => b.id), true);
      await t.pumpWidget(
        RewriteApp(
          library: library,
          picker: setup.NoPicker(),
          conversionDesktop: _Desktop(),
          initialLocation:
              '/books/${Uri.encodeComponent(books.first.id)}/information',
        ),
      );
      await settle(t);
      await t.tap(find.byKey(const ValueKey('workspace-book-picker')));
      await settle(t);
      await t.enterText(find.byType(TextField).last, books.last.title);
      await t.pump();
      await t.tap(
        find
            .descendant(
              of: find.byType(ListTile),
              matching: find.text(books.last.title),
            )
            .last,
      );
      await until(t, () => library.selection.value.current == books.last.id);
      expect(
        library.selection.value.current,
        books.last.id,
        reason: library.workspaceSave.value.message,
      );
      expect(library.selection.value.selected, books.map((b) => b.id).toSet());
      final router = GoRouter.of(
        t.element(find.byKey(const ValueKey('workspace-book-picker'))),
      );
      expect(router.routeInformationProvider.value.uri.pathSegments, [
        'books',
        books.last.id,
        'information',
      ]);
      final format = find.byWidgetPredicate(
        (w) =>
            w is DeskChoice<String> &&
            w.key.toString().contains('quick-format-'),
      );
      await t.tap(format);
      await t.pumpAndSettle();
      await t.tap(find.text('KFX').last);
      await until(
        t,
        () => find
            .byKey(const ValueKey('quick-format-KFX'))
            .evaluate()
            .isNotEmpty,
      );
      router.go('/conversion');
      await until(t, () => find.byType(ConversionPage).evaluate().isNotEmpty);
      await settle(t);
      expect(
        t.widget<ConversionPage>(find.byType(ConversionPage)).draft.format,
        'KFX',
      );
      router.go('/');
      await until(t, () => find.byType(LibraryPage).evaluate().isNotEmpty);
      await settle(t);
      expect(find.byType(LibraryPage), findsOneWidget);
      // V12（LIB-094）：书库页有勾选时，右下角按钮直接转换所选；
      // 在范围菜单改回“当前书”后，“转换当前书”仍只转当前书。
      expect(find.text('转换所选 ${books.length} 本'), findsOneWidget);
      expect(find.text('转换当前书'), findsNothing);
      await t.tap(find.text('已勾选 ${books.length} 本'));
      await t.pumpAndSettle();
      await t.tap(find.text('当前书').last);
      await t.pumpAndSettle();
      expect(find.text('转换当前书'), findsOneWidget);
      await t.tap(find.text('转换当前书'));
      await until(t, () => library.session.request != null);
      expect(library.session.request!.format, 'KFX');
      expect(library.session.request!.engine, 'D:/software/test/bokai.exe');
      expect(library.session.request!.books, [books.last.id]);
      expect(library.selection.value.selected, books.map((b) => b.id).toSet());
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
      var storageClosed = false;
      library.closeWorkspaceStorage().then((_) => storageClosed = true);
      await until(t, () => storageClosed);
      expect(storageClosed, true);
      library.dispose();
      state.dispose();
    },
  );
}
