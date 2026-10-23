// R2 书库界面（用户勾选 R2-01/02/03/05/06/08/09/10；R2-07 自动封面变化用户改为不做）：导入进度、失败清单、书架卡片、
// 概览的标签与统计、元数据映射的空状态。R2-10 拆分文件不改行为，由原有书库测试覆盖。
import 'dart:async';
import 'dart:io';

import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/folders/metadata_mapping_page.dart';
import 'package:easypub_desktop/desk/library/book_overview_page.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

class _Picker extends Fake implements BookFilePicker {
  _Picker([this.paths = const []]);
  final List<String> paths;
  @override
  Future<List<String>> chooseBooks() async => paths;
}

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

  void size(WidgetTester t, Size s) {
    t.view.physicalSize = s;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Future<void> until(WidgetTester t, bool Function() ready) async {
    for (var i = 0; i < 400; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (ready()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    fail('界面未就绪');
  }

  Widget app(Widget child) => MaterialApp(
    theme: deskTheme(),
    home: Scaffold(body: child),
  );

  testWidgets('导入：标题行显示进度；有失败时提示写数量，清单逐个列出原因（R2-01、R2-02）', (t) async {
    size(t, const Size(1500, 900));
    var gate = Completer<void>();
    late LegacyLibraryAdapter library;
    late PrototypeState state;
    final paths = <String>[];
    await t.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('desk-r2-import-');
      state = PrototypeState(
        settingsDirectory: '${root.path}/settings',
        importer: (path, cancelled) async {
          await gate.future;
          if (path.contains('损坏')) {
            throw const FormatException('无法识别文本编码，请另存为 UTF-8 后再导入。');
          }
          return readBook(path, cancelled);
        },
      );
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      for (final name in ['甲书', '损坏一', '乙书', '损坏二', '丙书']) {
        final f = File('${root.path}/$name.txt');
        await f.writeAsString('第一章 开始\n正文。\n');
        paths.add(f.path);
      }
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await t.pumpWidget(
      app(LibraryPage(library: library, picker: _Picker(paths))),
    );
    await t.pump();
    await t.tap(find.text('选择文件'));
    await until(
      t,
      () => find
          .byKey(const ValueKey('library-import-progress'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.text('正在导入 · 已加入 0 / 5'), findsOneWidget);
    expect(find.text('取消导入'), findsOneWidget);
    gate.complete();
    await until(
      t,
      () => find
          .byKey(const ValueKey('library-import-progress'))
          .evaluate()
          .isEmpty,
    );
    await until(t, () => find.text('已导入 3 本，2 个文件没有导入').evaluate().isNotEmpty);
    await t.pump(const Duration(milliseconds: 800));
    await t.tap(find.byKey(const ValueKey('library-import-failures-open')));
    await t.pumpAndSettle();
    final dialog = find.byKey(const ValueKey('library-import-failures'));
    expect(dialog, findsOneWidget);
    expect(find.text('2 个文件没有导入'), findsOneWidget);
    for (final name in ['损坏一.txt', '损坏二.txt']) {
      expect(
        find.descendant(of: dialog, matching: find.text(name)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(
        of: dialog,
        matching: find.text('无法识别文本编码，请另存为 UTF-8 后再导入。'),
      ),
      findsNWidgets(2),
    );
    expect(
      find.byKey(const ValueKey('library-import-failures-copy')),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('书架卡片写作者、格式与章数；待核角标带“待核”（R2-08）', (t) async {
    size(t, const Size(1500, 900));
    late LegacyLibraryAdapter library;
    late PrototypeState state;
    late String id;
    await t.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('desk-r2-shelf-');
      state = PrototypeState(settingsDirectory: '${root.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final f = File('${root.path}/甲书.txt');
      await f.writeAsString('第一章 开始\n正文\n第二章 继续\n正文\n第四章 跳号\n正文\n');
      await library.importFiles([f.path]);
      id = library.books.value.single.id;
      final checks = library.openChecks(id);
      try {
        await checks.inspect();
      } finally {
        checks.dispose();
      }
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await t.pumpWidget(app(LibraryPage(library: library, picker: _Picker())));
    await until(t, () => find.text('TXT · 3 章').evaluate().isNotEmpty);
    final row = find.byKey(ValueKey('library-row-$id'));
    expect(
      find.descendant(of: row, matching: find.text('TXT · 3 章')),
      findsOneWidget,
    );
    final badge = find.byKey(ValueKey('library-badge-$id'));
    expect(
      find.descendant(of: badge, matching: find.text('待核')),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('概览：卷章字数并成一行，标签不再像按钮，语言未设置可点（R2-05、R2-06）', (t) async {
    size(t, const Size(1100, 720));
    late LegacyLibraryAdapter library;
    late PrototypeState state;
    late String id;
    await t.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('desk-r2-overview-');
      state = PrototypeState(settingsDirectory: '${root.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final f = File('${root.path}/甲书.txt');
      await f.writeAsString('第一章 开始\n正文\n第二章 继续\n正文\n');
      await library.importFiles([f.path]);
      id = library.books.value.single.id;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await t.pumpWidget(app(BookOverviewPage(library: library, bookId: id)));
    await until(t, () => find.textContaining('字号').evaluate().isNotEmpty);
    expect(find.byType(Chip), findsNothing);
    for (final field in ['volumes', 'chapters', 'characters']) {
      expect(find.byKey(ValueKey('overview-stat-$field')), findsOneWidget);
    }
    // 三项数字在书籍信息卡里，同一行。
    final y = t
        .getTopLeft(find.byKey(const ValueKey('overview-stat-volumes')))
        .dy;
    expect(
      t.getTopLeft(find.byKey(const ValueKey('overview-stat-characters'))).dy,
      y,
    );
    // 制作进度在 720 高的窗口里能看到前几行。
    expect(t.getTopLeft(find.text('章节检查')).dy, lessThan(720));
    final language = find.byKey(const ValueKey('overview-language'));
    expect(
      find.descendant(of: language, matching: find.text('语言未设置')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: language, matching: find.byType(GestureDetector)),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('元数据映射：没有规则时有示例与“添加第一条规则”；没有改动时不显示“放弃未应用规则”（R2-09）', (t) async {
    size(t, const Size(1500, 900));
    late LegacyLibraryAdapter library;
    late PrototypeState state;
    await t.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('desk-r2-mapping-');
      state = PrototypeState(settingsDirectory: '${root.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await t.pumpWidget(
      app(
        MetadataMappingPage(
          library: library,
          picker: _Picker(),
          navigation: MappingNavigationGuard(),
        ),
      ),
    );
    await until(
      t,
      () => find.byKey(const ValueKey('mapping-empty')).evaluate().isNotEmpty,
    );
    expect(find.text('放弃未应用规则'), findsNothing);
    await t.tap(find.byKey(const ValueKey('mapping-add-first')));
    await t.pump();
    expect(find.byKey(const ValueKey('mapping-empty')), findsNothing);
    expect(find.text('目录规则 1'), findsOneWidget);
    expect(find.text('放弃未应用规则'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
