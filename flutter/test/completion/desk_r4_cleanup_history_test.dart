import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/cleanup/cleanup_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/history/change_history_page.dart';

/// R4：文本清理与变更记录的界面打磨（CLEAN-106～111、HIS-021～023）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  void size(WidgetTester t, Size s) {
    t.view.physicalSize = s;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

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

  Future<LegacyLibraryAdapter> open(WidgetTester t, String text) async {
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('r4-clean-'))
          .absolute;
      state = PrototypeState(settingsDirectory: '${root.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('${root.path}/样书.txt')..writeAsStringSync(text);
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    return library;
  }

  Widget app(Widget child, {double scale = 1}) => MaterialApp(
    theme: deskTheme(),
    builder: (context, page) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: page!,
    ),
    home: Scaffold(body: child),
  );

  // 第一章第 3–5 行是三个连续空行；第 6 行行尾有空格。
  const sample = '第一章 开始\n甲文\n\n\n\n\n乙文  \n第二章 后续\n丙文\n';

  Widget page(LegacyLibraryAdapter library) => CleanupPage(
    library: library,
    bookId: library.books.value.single.id,
    navigation: CleanupNavigationGuard(),
    onChecks: () {},
  );

  testWidgets('连续空行合并成一行，可逐行展开；各行操作区等宽；文案（CLEAN-106/107/109）', (t) async {
    size(t, const Size(1500, 1000));
    final library = await open(t, sample);
    await t.pumpWidget(app(page(library)));
    await until(t, () => find.textContaining('处可预览').evaluate().isNotEmpty);
    expect(find.text('去掉行尾空白、多余空行和广告行；原稿始终保留'), findsOneWidget);
    // 宽窗 1.0 倍：两栏，没有“清理规则 / 预览与候选”切换。
    expect(find.text('预览与候选'), findsNothing);
    final group = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('cleanup-blank-group-'),
    );
    expect(group, findsOneWidget);
    expect(find.textContaining('个连续空行）'), findsOneWidget);
    await t.tap(group);
    await t.pump();
    await t.tap(find.text('逐行'));
    await until(t, () => group.evaluate().isEmpty);
    expect(group, findsNothing, reason: '展开后逐行列出');
    expect(find.text('（删除此行）'), findsWidgets);
    // 空白标记开关在“⋯”菜单里。
    await t.tap(find.byKey(const ValueKey('cleanup-view-menu')));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('显示空白标记'), findsOneWidget);
    await t.tap(find.text('显示空白标记'));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const ValueKey('cleanup-view-menu')));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('隐藏空白标记'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump(const Duration(milliseconds: 400));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('窄窗大字号时改为切换显示（CLEAN-108）', (t) async {
    size(t, const Size(1100, 800));
    final library = await open(t, sample);
    await t.pumpWidget(app(page(library), scale: 1.3));
    await until(t, () => find.text('查看清理差异…').evaluate().isNotEmpty);
    expect(find.text('预览与候选'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('清理记录写成中文说明，原始字段折叠在技术细节；类型筛选带数量（HIS-021/023）', (t) async {
    size(t, const Size(1500, 1000));
    final library = await open(t, sample);
    final id = library.books.value.single.id;
    await t.runAsync(() async {
      final cleanup = library.openCleanup(id);
      try {
        final plan = await cleanup.preview(
          jsonEncode({
            'kind': 'cleanup',
            'pipeline': [
              {'kind': 'trim_trailing_spaces'},
              {'kind': 'collapse_blank_lines'},
            ],
            'start_line': 2,
          }),
        );
        await cleanup.apply(plan);
      } finally {
        cleanup.dispose();
      }
    });
    final history = library.openChangeHistory();
    final record = history.records(id).firstWhere((r) => r.domain == '文本清理');
    expect(record.title, '采用文本清理 · 2 条规则');
    final detail = history.detail(record);
    expect(detail.fields.map((f) => f.label), ['清理规则', '范围', '保留原文', '提示候选']);
    expect(detail.fields[0].before, '未清理（使用原稿）');
    expect(detail.fields[0].after, '行尾空白、合并连续空行');
    expect(detail.fields[1].after, '源行 2–末尾');
    expect(detail.technical, isNotEmpty);
    expect(
      detail.fields.any((f) => f.after.contains('trim_trailing_spaces')),
      false,
      reason: '内部名称只在技术细节里',
    );

    await t.pumpWidget(
      app(
        ChangeHistoryPage(
          library: library,
          history: history,
          bookId: id,
          openEditor: (_, _) {},
        ),
      ),
    );
    await t.pump();
    expect(find.text('采用文本清理 · 2 条规则'), findsWidgets);
    expect(find.textContaining('技术细节'), findsOneWidget);
    expect(find.textContaining('trim_trailing_spaces'), findsNothing);
    expect(find.text('全部类型 ${history.records(id).length}'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('章节页的紧凑变更记录可重做，状态写“已应用”（HIS-022）', (t) async {
    size(t, const Size(1200, 900));
    final library = await open(t, sample);
    final id = library.books.value.single.id;
    final history = library.openChangeHistory();
    await t.runAsync(() async {
      final cleanup = library.openCleanup(id);
      try {
        await cleanup.apply(
          await cleanup.preview(
            jsonEncode({
              'kind': 'cleanup',
              'pipeline': [
                {'kind': 'trim_trailing_spaces'},
              ],
            }),
          ),
        );
        final record = history
            .records(id)
            .firstWhere((r) => r.domain == '文本清理');
        await history.undo(history.detail(record));
      } finally {
        cleanup.dispose();
      }
    });
    await t.pumpWidget(
      app(
        ChangeHistoryPage(
          library: library,
          history: history,
          bookId: id,
          compact: true,
          openEditor: (_, _) {},
        ),
      ),
    );
    await t.pump();
    expect(find.textContaining('已撤销'), findsOneWidget);
    await t.tap(find.textContaining('采用文本清理'));
    await t.pumpAndSettle();
    expect(find.text('重做此次修改'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
