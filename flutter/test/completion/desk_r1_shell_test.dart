// R1 全局外壳（正式版打磨）：选书弹窗、快速排版先比较后应用、命令菜单统一、窄窗底栏、
// 命令面板的章节与设置项、设置项定位、页面导航最近访问、保存状态浮层。
import 'dart:io';

import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/settings/settings_index.dart';
import 'package:easypub_desktop/desk/shell/page_menu.dart';
import 'package:easypub_desktop/desk/shell/save_badge.dart';
import 'package:easypub_desktop/desk/widgets.dart' show DeskSegmented;
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _NoPicker extends Fake implements BookFilePicker {}

void main() {
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
  });

  /// 三本书：山海之间（两卷六章）、龙游令、神通者；打开真实 RewriteApp。
  Future<(LegacyLibraryAdapter, GoRouter, Future<void> Function())> app(
    WidgetTester t, {
    Size size = const Size(1440, 900),
    String location = '/',
  }) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final tmp = await Directory.systemTemp.createTemp('desk-r1-');
      final state = PrototypeState(settingsDirectory: '${tmp.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final files = <String>[];
      for (final (name, text) in [
        (
          '山海之间',
          '第一卷 远行\n第一章 出门\n山路很长。\n第二章 渡河\n河水很急。\n第三章 入山\n山很高。\n'
              '第二卷 归来\n第四章 回望\n风很轻。\n第五章 渡海\n海很蓝。\n第六章 到家\n灯亮了。\n',
        ),
        ('龙游令', '第一章 开端\n正文。\n第二章 继续\n正文。\n'),
        ('神通者', '第一章 开端\n正文。\n第二章 继续\n正文。\n'),
      ]) {
        final f = File('${tmp.path}/$name.txt');
        await f.writeAsString(text);
        files.add(f.path);
      }
      expect(
        (await library.importFiles(files)).every((r) => r.succeeded),
        true,
      );
    });
    library.selectBook(
      library.books.value.firstWhere((b) => b.title == '山海之间').id,
    );
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
      }
    }

    await t.pumpWidget(
      RewriteApp(
        library: library,
        picker: _NoPicker(),
        initialLocation: location,
      ),
    );
    await settle();
    final router = GoRouter.of(
      t.element(find.byKey(const ValueKey('workspace-output-bar'))),
    );
    return (library, router, settle);
  }

  testWidgets('选书弹窗：显示格式、章数与当前书，↓ 与回车打开', (t) async {
    final (library, _, settle) = await app(t);
    await t.tap(find.byKey(const ValueKey('workspace-book-picker')).first);
    await settle();
    final current = library.books.value.firstWhere((b) => b.title == '山海之间');
    final row = find.byKey(ValueKey('book-picker-row-${current.id}'));
    expect(row, findsOne);
    expect(
      find.descendant(of: row, matching: find.text(' · 2 卷 · 6 章')),
      findsOne,
    );
    expect(find.descendant(of: row, matching: find.text('当前')), findsOne);
    // 搜索后 ↓ 选第一行、回车打开。
    await t.enterText(find.byKey(const ValueKey('book-picker-search')), '龙游');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle();
    expect(
      library.books.value
          .firstWhere((b) => b.id == library.selection.value.current)
          .title,
      '龙游令',
    );
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('快速排版：先列出与本书当前排版的不同，确认后才应用', (t) async {
    final (library, _, settle) = await app(t);
    final id = library.selection.value.current!;
    // 先把本书行距改成 1.8，出厂默认就与它不同了。
    await t.runAsync(() async {
      final session = library.openLayout(id);
      await session.apply(await session.preview({'line_height': 1.8}));
      session.dispose();
    });
    await t.tap(find.byTooltip('本次书稿排版预设').first);
    await settle();
    expect(find.text('选择排版'), findsOne);
    expect(find.textContaining('行距'), findsWidgets);
    await t.tap(find.text('出厂默认排版'));
    await settle();
    // 只列行距一项（内部的设置来源记录不列出）。
    expect(find.text('将改动 1 项：'), findsOne);
    expect(find.textContaining('1.8  →  1.2', findRichText: true), findsOne);
    // 还没确认：本书行距仍是 1.8。
    await t.runAsync(() async {
      final session = library.openLayout(id);
      expect(session.saved['line_height'], 1.8);
      session.dispose();
    });
    await t.tap(find.byKey(const ValueKey('quick-layout-apply')));
    await settle();
    expect(find.text('选择排版'), findsNothing);
    await t.runAsync(() async {
      final session = library.openLayout(id);
      expect(session.saved['line_height'], isNot(1.8));
      session.dispose();
    });
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('命令菜单：当前值与勾选条目打勾、条目紧凑、点选当帧执行', (t) async {
    String? picked;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Center(
            child: DeskCommandMenu<String>(
              tooltip: '排序',
              initialValue: 'b',
              onSelected: (v) => picked = v,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'a', child: Text('甲')),
                PopupMenuItem(value: 'b', child: Text('乙')),
                PopupMenuDivider(),
                CheckedPopupMenuItem(
                  value: 'c',
                  checked: true,
                  child: Text('丙'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byTooltip('排序'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    final panel = find.byKey(deskMenuPanelKey);
    expect(panel, findsOne);
    // 乙（当前值）与丙（勾选条目）打勾，甲不打勾。
    expect(
      find.descendant(of: panel, matching: find.byIcon(Icons.check_rounded)),
      findsNWidgets(2),
    );
    expect(
      t
          .getSize(
            find
                .ancestor(of: find.text('甲'), matching: find.byType(InkWell))
                .first,
          )
          .height,
      lessThanOrEqualTo(36),
    );
    await t.tap(find.descendant(of: panel, matching: find.text('甲')));
    expect(picked, 'a');
    await t.pumpAndSettle();
    expect(panel, findsNothing);
  });

  testWidgets('窄选择框的长选项不被截断：面板至少 360 宽，文字在面板内省略', (t) async {
    const long = '文件：yckceo-1316-20261020-133502-一个很长很长的书源文件名称.json';
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: SizedBox(
                width: 190,
                child: DeskChoice<String>(
                  key: const ValueKey('scope'),
                  value: '',
                  items: const [
                    DropdownMenuItem(value: '', child: Text('全部来源与分组')),
                    DropdownMenuItem(value: 'f', child: Text(long)),
                  ],
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('scope')));
    await t.pumpAndSettle();
    final option = t.getRect(find.text(long).last);
    // 面板至少 360 宽，选项文字按面板宽度省略（面板 360 − 内边距与勾 64 = 296）；
    // V94 时面板只有约 280 宽，文字却按 420 排，超出的部分被面板裁掉（用户截图）。
    expect(option.width, lessThanOrEqualTo(296));
    expect(t.takeException(), isNull);
  });

  testWidgets('窄窗底栏：格式仍是分段按钮，排版按钮只写“排版”', (t) async {
    await app(t, size: const Size(980, 720));
    final tray = find.byKey(const ValueKey('workspace-output-bar'));
    expect(
      find.descendant(of: tray, matching: find.byType(DeskSegmented<String>)),
      findsOne,
    );
    expect(find.descendant(of: tray, matching: find.text('排版')), findsOne);
    expect(find.byTooltip('本次书稿排版预设：沿用本书排版'), findsOne);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('命令面板：输入章节名跳到该章，输入设置项打开分组并框出', (t) async {
    final (_, router, settle) = await app(t);
    Future<void> palette(String query) async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyK);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle();
      await t.enterText(
        find.byKey(const ValueKey('desk-command-query')),
        query,
      );
      await settle();
    }

    await palette('渡海');
    expect(find.textContaining('章节 · 山海之间'), findsOne);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle();
    final uri = router.routeInformationProvider.value.uri;
    expect(uri.path, endsWith('/chapters'));
    expect(uri.queryParameters['node'], isNotEmpty);

    await palette('减少动画');
    expect(find.text('设置 · 外观与交互'), findsOne);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(router.routeInformationProvider.value.uri.path, '/settings');
    expect(find.byKey(const ValueKey('settings-focus-flash')), findsOne);
    await settle();
    await t.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('settings-focus-flash')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('设置项索引里的每一项都出现在它所在的分组', (t) async {
    final (_, router, settle) = await app(t);
    for (var tab = 0; tab < settingsTabNames.length; tab++) {
      router.go('/settings?tab=$tab');
      await settle();
      for (final (label, at, _) in settingsIndex.where((e) => e.$2 == tab)) {
        expect(
          find.text(label),
          findsWidgets,
          reason: '$label 应在 ${settingsTabNames[at]}',
        );
      }
    }
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('页面导航：最近访问加当前书的页面，不再重复全局页面', (t) async {
    final (library, router, settle) = await app(t);
    final id = Uri.encodeComponent(library.selection.value.current!);
    for (final path in [
      '/settings',
      '/books/$id/layout',
      '/books/$id/chapters',
    ]) {
      router.go(path);
      await settle();
    }
    expect(recentPages.value.first, '/books/$id/chapters');
    await t.tap(find.byTooltip('页面导航').first);
    await settle();
    expect(find.text('最近访问'), findsOne);
    expect(find.text('排版 · 山海之间'), findsOne);
    expect(find.text('设置'), findsWidgets);
    // 底栏也写着“当前书 · 山海之间”，所以按菜单里独有的条目核对。
    expect(find.text('书籍信息与封面'), findsOne);
    expect(find.text('文件夹元数据映射'), findsNothing);
    await t.tap(find.text('排版 · 山海之间'));
    await settle();
    expect(router.routeInformationProvider.value.uri.path, '/books/$id/layout');
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('保存状态：点击打开浮层，有上次保存时间与立即保存', (t) async {
    final (_, _, settle) = await app(t);
    await t.tap(find.byKey(const ValueKey('desk-save-badge')));
    await settle();
    final panel = find.byKey(const ValueKey('desk-save-panel'));
    expect(panel, findsOne);
    expect(
      find.descendant(of: panel, matching: find.textContaining('草稿保存在本机')),
      findsOne,
    );
    expect(find.byKey(const ValueKey('desk-save-now')), findsOne);
    await t.pumpWidget(const SizedBox.shrink());
    // 有保存时间与失败原因时都写出来；失败时按钮是“重试”。
    var saved = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: DeskSaveBadge(
              state: DeskSaveState.failed,
              message: '磁盘已满，草稿没有写入。',
              savedAt: DateTime.now(),
              onTap: () => saved++,
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('desk-save-badge')));
    await t.pumpAndSettle();
    expect(find.textContaining('上次保存：今天'), findsOne);
    expect(find.text('磁盘已满，草稿没有写入。'), findsOne);
    await t.tap(find.text('重试'));
    expect(saved, 1);
  });
}
