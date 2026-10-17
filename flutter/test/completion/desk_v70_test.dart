import 'dart:io';

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
import 'package:easypub_desktop/desk/shell/command_palette.dart';

class NoPicker extends Fake implements BookFilePicker {}

/// V70：命令面板加强（G-074 当前书、G-075 最近使用、G-076 按书名切换）。
void main() {
  testWidgets('面板：未输入时最近使用在最上方且不重复，只在搜索时出现的命令要输入后才有', (t) async {
    final ran = <String>[], recorded = <String>[];
    DeskCommand cmd(
      String label, {
      String group = '页面',
      bool searchOnly = false,
    }) => DeskCommand(
      id: 'G-999',
      label: label,
      group: group,
      initials: '',
      searchOnly: searchOnly,
      run: () => ran.add(label),
    );
    final commands = [
      cmd('书库'),
      cmd('设置'),
      cmd('打开：雾港来信', group: '书稿', searchOnly: true),
    ];
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDeskCommandPalette(
                context,
                commands,
                recent: [commands[1].key, 'G-000|已不存在', commands[2].key],
                onRun: (c) => recorded.add(c.key),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    final labels = t
        .widgetList<Text>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Text),
          ),
        )
        .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
        .where((s) => s.isNotEmpty && s != 'G-999')
        .toList();
    expect(labels, ['最近使用', '设置', '打开：雾港来信', '页面', '书库']);
    await t.enterText(find.byKey(const ValueKey('desk-command-query')), '雾港');
    await t.pump();
    expect(find.text('书稿'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(recorded, [commands[2].key]);
    expect(ran, ['打开：雾港来信']);
  });

  testWidgets('整机：当前书组、按书名切换、最近使用随工作区保存', (t) async {
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
      final tmp = (await Directory('../artifacts').createTemp('v70-')).absolute;
      state = PrototypeState(settingsDirectory: '${tmp.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      for (final name in ['山海之间', '雾港来信']) {
        final f = File('${tmp.path}/$name.txt')
          ..writeAsStringSync('第一章 远行\n山路很长。\n第二章 归来\n海风很轻。\n');
        expect((await library.importFiles([f.path])).single.succeeded, true);
      }
      a = library.books.value.firstWhere((x) => x.title == '山海之间').id;
      b = library.books.value.firstWhere((x) => x.title == '雾港来信').id;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> settle() async {
      for (var i = 0; i < 50; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> palette() async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyK);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle();
    }

    /// 解码后的路径段（书的编号含冒号与反斜杠，编码方式可能不同）。
    String path() =>
        GoRouter.of(t.element(find.byType(Scaffold).first))
            .routeInformationProvider
            .value
            .uri
            .pathSegments
            .join('|');

    await t.pumpWidget(
      RewriteApp(
        library: library,
        picker: NoPicker(),
        initialLocation: '/books/${Uri.encodeComponent(a)}/overview',
      ),
    );
    await settle();
    await palette();
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('当前书 · 山海之间'),
      ),
      findsOneWidget,
    );
    for (final f in ['EPUB', 'AZW3', 'MOBI', 'KFX']) {
      expect(find.text('转换当前书为 $f'), findsOneWidget);
    }
    expect(find.text('打开：雾港来信'), findsNothing, reason: '未输入时不列书名');

    // 按书名切换。
    await t.enterText(find.byKey(const ValueKey('desk-command-query')), '雾港');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle();
    expect(path(), 'books|$b|overview');

    // 当前书组跟着变；打开“识别与检查规则”。
    await palette();
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('当前书 · 雾港来信'),
      ),
      findsOneWidget,
    );
    expect(find.text('最近使用'), findsOneWidget);
    await t.enterText(
      find.byKey(const ValueKey('desk-command-query')),
      'sbyjcgz',
    );
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle();
    expect(path(), 'books|$b|rules');

    // 最近使用：随工作区保存，最近的在前。
    final saved = library.readDraft('workspace/palette')!['recent'] as List;
    expect(saved, ['G-074|识别与检查规则', 'G-076|打开：雾港来信']);
    await palette();
    final recentRows = find.descendant(
      of: find.byType(ListView),
      matching: find.text('识别与检查规则'),
    );
    expect(recentRows, findsOneWidget, reason: '最近使用里出现，原组里不重复');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();
    expect(t.takeException(), isNull);
  });
}
