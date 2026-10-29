import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/rules/numeric_dialog.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

/// V25：数字章节合并为“列出 → 预览识别与改写 → 核对 → 一批应用”（CH-263）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('原行文字：新增项取摘录里的标题行，第 1 行取摘录首行', () {
    expect(
      numericOriginalLine({
        'kind': 'added',
        'line': 5,
        'excerpt': '上一行\n12、开端\n正文',
      }),
      '12、开端',
    );
    expect(
      numericOriginalLine({'kind': 'added', 'line': 1, 'excerpt': '1 起\n正文'}),
      '1 起',
    );
    expect(numericOriginalLine({'kind': 'changed', 'before': '旧标题'}), '旧标题');
  });

  testWidgets('数字标题：预览识别并改写为第X章，取消改写只识别，核对后一批应用', (t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v25-numeric-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final text = StringBuffer('序言\n');
      for (final (n, title) in [(1, '开端'), (2, '夜雨'), (12, '归途')]) {
        text.writeln('$n、$title');
        text.writeln('　　$title的第一段正文。');
        text.writeln('　　$title的第二段正文。');
        text.writeln('　　$title的第三段正文。');
      }
      final file = File('$root/数字.txt')..writeAsStringSync('$text');
      await library.importFiles([file.path]);
      id = state.currentId;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump();
      }
    }

    bool? applied;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => applied = await showNumericChaptersDialog(
                context,
                service: library,
                bookId: id,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开'));
    await settle();
    final summary = find.byKey(const ValueKey('numeric-summary'));
    // V113：内置规则要求数字标题后至少 3 行正文（原为 5），样书每章 3 行，直接找到。
    expect(find.byKey(const ValueKey('numeric-minimum')), findsOneWidget);
    expect(t.widget<Text>(summary).data, '找到 3 个数字标题 · 新增章节 3 · 改写标题 0');
    await t.enterText(find.byKey(const ValueKey('numeric-minimum')), '4');
    await t.tap(find.text('重新预览'));
    await settle();
    expect(t.widget<Text>(summary).data, '没有找到需要识别或改写的数字标题。');
    await t.enterText(find.byKey(const ValueKey('numeric-minimum')), '3');
    await t.tap(find.text('重新预览'));
    await settle();
    expect(t.widget<Text>(summary).data, '找到 3 个数字标题 · 新增章节 3 · 改写标题 0');
    expect(find.text('12、归途'), findsOneWidget);
    expect(find.text('第十二章 归途'), findsOneWidget);
    // 未核对不能应用。
    expect(
      t
          .widget<DeskButton>(find.byKey(const ValueKey('numeric-apply')))
          .onPressed,
      isNull,
    );

    // 取消改写：只识别，标题保持原样（原行与新标题相同时不重复显示）。
    await t.tap(find.byKey(const ValueKey('numeric-normalize')));
    await settle();
    expect(find.text('第十二章 归途'), findsNothing);
    expect(find.text('12、归途'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('numeric-normalize')));
    await settle();

    await t.tap(find.byKey(const ValueKey('numeric-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('numeric-apply')));
    await settle();
    expect(applied, true);
    final titles = await t.runAsync(() async {
      final chapters = library.openChapters(id);
      final page = await chapters.read(0);
      return page.nodes.map((n) => n.title).toList();
    });
    expect(titles, containsAll(['第一章 开端', '第二章 夜雨', '第十二章 归途']));
    await t.pumpWidget(const SizedBox());
  });
}
