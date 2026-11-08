import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/library/generated_cover.dart';
import 'package:easypub_desktop/desk/tokens.dart';
import 'package:easypub_desktop/desk/widgets.dart' show formatFileSize;

class _NoPicker extends Fake implements BookFilePicker {}

/// V16：转换页、任务页、转换历史与成品验收（OUT-070–073、TASK-024–028）。
/// 真实应用、真实 Rust、真实 Kindling 转出 EPUB。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('转出的生成封面与书库同一画法：纸色底、按书名固定的墨色书脊（OUT-070）', () async {
    final root = await Directory('../artifacts').createTemp('v16-cover-');
    final path = await renderGeneratedCover('雾港来信', '林沉舟', root);
    final codec = await ui.instantiateImageCodec(
      await File(path).readAsBytes(),
    );
    final image = (await codec.getNextFrame()).image;
    expect((image.width, image.height), (1200, 1600));
    final pixels = (await image.toByteData())!;
    Color at(int x, int y) {
      final i = (y * image.width + x) * 4;
      return Color.fromARGB(
        pixels.getUint8(i + 3),
        pixels.getUint8(i),
        pixels.getUint8(i + 1),
        pixels.getUint8(i + 2),
      );
    }

    // 书脊（宽 7%）是这本书固定的墨色；书脊以外是编辑台的纸色，不再是绿底。
    expect(at(30, 800), coverInkFor('雾港来信'));
    expect(at(600, 40), Desk.light.paper);
    expect(at(600, 1560), Desk.light.paper);
    image.dispose();
    codec.dispose();
    expect(formatFileSize(512), '512 字节');
    expect(formatFileSize(12335), '12.0 KB');
    expect(formatFileSize(3 * 1024 * 1024), '3.0 MB');
  });

  testWidgets('转换页、任务页、历史与验收按 V16 显示', (t) async {
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
    t.view.physicalSize = const Size(1500, 950);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String foggy, night, root;
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp('v16-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final text = StringBuffer('第一卷 潮声\n');
      for (var i = 1; i <= 4; i++) {
        if (i == 3) continue; // 缺第三章：章节问题
        text.writeln('第$i章 雾起$i\n　　港口的雾又起来了。');
      }
      for (final (name, body) in [
        ('雾港来信', text.toString()),
        ('夜航船', '第1章 夜\n　　正文。\n第2章 航\n　　正文。\n'),
      ]) {
        final file = File('$root/$name.txt')..writeAsStringSync(body);
        expect((await library.importFiles([file.path])).single.succeeded, true);
      }
      foggy = library.books.value.firstWhere((b) => b.title == '雾港来信').id;
      night = library.books.value.firstWhere((b) => b.title == '夜航船').id;
      for (final b in library.books.value) {
        final checks = library.openChecks(b.id);
        try {
          await checks.inspect();
        } finally {
          checks.dispose();
        }
      }
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> settle() async {
      for (var i = 0; i < 60; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 30));
      }
    }

    await t.pumpWidget(RewriteApp(library: library, picker: _NoPicker()));
    await settle();
    final router = GoRouter.of(t.element(find.byType(Navigator).first));

    // 任务页空状态（TASK-027）。
    router.go('/tasks');
    await settle();
    expect(find.byKey(const ValueKey('tasks-empty')), findsOneWidget);
    expect(find.text('还没有转换任务'), findsOneWidget);
    expect(find.text('停止队列'), findsNothing);
    expect(t.takeException(), isNull);

    // 转换页：与书库一致的卷章与状态、三态全选、将生成的文件名（OUT-071–073）。
    router.go(
      Uri(
        path: '/conversion',
        queryParameters: {
          'books': [foggy],
        },
      ).toString(),
    );
    await settle();
    expect(
      find.descendant(
        of: find.byKey(ValueKey('conversion-status-$foggy')),
        matching: find.textContaining('待核对 '),
      ),
      findsOneWidget,
    );
    expect(find.text('1 卷 · 3 章'), findsOneWidget);
    final all = t.widget<Checkbox>(
      find.byKey(const ValueKey('conversion-select-all')),
    );
    expect(all.tristate, true);
    expect(all.value, isNull); // 两本里选了一本：半选
    expect(find.text('雾港来信.epub'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('conversion-summary-issues')),
      findsOneWidget,
    );
    expect(find.textContaining('本次输出 ·'), findsNothing);
    // 页面列出的文件名与真实转换的命名规则一致（不含同名序号）。
    final planned = LegacyConversionSession(state);
    expect(planned.plannedFileName(night, 'AZW3'), '夜航船.azw3');
    await t.runAsync(() => library.savePatch({'output_naming': 'filename'}));
    expect(planned.plannedFileName(night, 'EPUB'), '夜航船.epub');
    await t.runAsync(() => library.savePatch({'output_naming': 'title'}));
    planned.dispose();
    expect(t.takeException(), isNull);

    // 真实转换两本 EPUB，再看任务页、历史与验收。
    String? taskId;
    String? outputPath;
    await t.runAsync(() async {
      final session = LegacyConversionSession(state);
      final plan = await session.preview(
        ConversionRequest(
          books: [foggy, night],
          directory: '$root/output',
          format: 'EPUB',
          engine: Platform.environment['EASYPUB_TEST_KINDLING']!,
          generateCover: true,
          runChecks: false,
        ),
      );
      final outputs = await session.commit(plan, acknowledgeWarnings: true);
      expect(outputs.every((o) => o.complete), true);
      taskId = outputs.firstWhere((o) => o.bookId == foggy).taskId;
      outputPath = outputs.firstWhere((o) => o.bookId == foggy).path;
      session.dispose();
    });
    expect(File(outputPath!).uri.pathSegments.last, '雾港来信.epub');

    await t.pumpWidget(const SizedBox());
    await settle();
    await t.pumpWidget(RewriteApp(library: library, picker: _NoPicker()));
    await settle();
    final again = GoRouter.of(t.element(find.byType(Navigator).first));
    again.go('/tasks');
    await settle();
    // 标题与筛选（TASK-024）：只显示有数量的分类，空闲时没有“停止队列”。
    expect(find.text('转换任务'), findsWidgets);
    expect(find.textContaining('失败 0'), findsNothing);
    expect(find.text('停止队列'), findsNothing);
    expect(find.text('新建转换'), findsOneWidget);
    // 任务行写大小（TASK-025）；详情标题是文件名、步骤横排、没有“覆盖策略”（TASK-026）。
    final size = formatFileSize(File(outputPath!).lengthSync());
    expect(find.textContaining(size), findsWidgets);
    expect(find.byKey(const ValueKey('task-stages')), findsOneWidget);
    expect(find.text('覆盖策略'), findsNothing);
    final title = t.widget<Text>(
      find.byKey(const ValueKey('task-detail-title')),
    );
    expect(title.data, endsWith('.epub'));
    expect(find.textContaining('..'), findsNothing);
    expect(t.takeException(), isNull);

    // 成品验收：大小写 KB、作者为空不多出“·”、路径规范化（TASK-028）。
    again.go('/tasks/output/${Uri.encodeComponent(taskId!)}');
    await settle();
    expect(find.text(size), findsOneWidget);
    expect(find.textContaining('MiB'), findsNothing);
    expect(find.textContaining(' ·  · '), findsNothing);
    expect(find.textContaining('..'), findsNothing);
    expect(t.takeException(), isNull);

    // 转换历史只有一页：不显示翻页。
    again.go('/tasks/history');
    await settle();
    expect(find.text('上一页'), findsNothing);
    expect(find.text('下一页'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await settle();
  });
}
