// 页面巡检图集（V15）：真实应用 + 真实 Rust，三本样书，13 个页面 × 三种窗口宽度截图。
// 运行：tools/test_flutter.ps1 -TestPaths @('tool/capture_page_atlas_test.dart')
// 输出：artifacts/page-atlas-<日期>/<页面>-<宽度>.png 与 pages.json。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:easypub_desktop/desk/fonts.dart';

class _NoPicker extends Fake implements BookFilePicker {}

String _foggyHarbor() {
  final b = StringBuffer();
  b.writeln('雾港来信');
  b.writeln('作者：林沉舟');
  b.writeln('');
  b.writeln('第一卷 潮声');
  for (var i = 1; i <= 14; i++) {
    if (i == 9) continue; // 缺第九章：编号跳跃
    b.writeln(
      '第$i章 ${['雾起', '旧码头', '来信', '灯塔', '潮汐表', '渡口', '夜航', '回声', '', '雨巷', '钟楼', '信差', '暗流', '归帆'][i - 1]}',
    );
    b.writeln('　　港口的雾又起来了，远处的汽笛声一阵一阵传过来。  ');
    b.writeln('');
    b.writeln('');
    b.writeln('　　她把那封信又读了一遍，信纸边缘已经被潮气浸软。');
    b.writeln('　　“明天还会有船吗？”他问。');
    if (i == 6) b.writeln('两章合一章，求月票！');
  }
  b.writeln('第二卷 远岸');
  for (var i = 15; i <= 26; i++) {
    b.writeln('第$i章 ${i == 20 ? '暗流' : '远岸其$i'}'); // 第20章与第13章同名
    b.writeln('　　船驶出港口的时候，天刚亮。甲板上的人都不说话。');
    b.writeln('　　海面很平，像一块没有尽头的灰色玻璃。');
  }
  return b.toString();
}

String _simple(String title, int count) => [
  for (var i = 1; i <= count; i++)
    '第$i章 $title之$i\n　　这是第$i章的正文，句子不长，用来撑出几行段落。\n　　第二段继续写下去。\n',
].join();

void main() {
  testWidgets('page atlas', (t) async {
    const channel = MethodChannel('window_manager');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    // 测试环境默认把阴影画成实心色块；巡检图要与真实窗口一致，打开真实阴影。
    debugDisableShadows = false;
    final date = DateTime.now();
    final stamp =
        '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
    // ATLAS_NAME 改输出目录名（例如只截几页时不覆盖整套图集）；
    // ATLAS_PAGES 只截列出的页面（逗号分隔，例如 library,overview）。
    final out = Directory(
      '../artifacts/${Platform.environment['ATLAS_NAME'] ?? 'page-atlas-$stamp'}',
    );
    final only = Platform.environment['ATLAS_PAGES']?.split(',').toSet();
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String bookId;
    String? taskId;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      // 与正式入口相同：登记编辑台字体族（Desk Sans / Serif / Mono）。
      await loadDeskFonts();
      for (final font in {
        'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(font.key)..addFont(
              File(font.value).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
      }
      if (out.existsSync()) out.deleteSync(recursive: true);
      out.createSync(recursive: true);
      final root = (await out.createTemp('data-')).absolute.path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      for (final (name, text) in [
        ('雾港来信', _foggyHarbor()),
        ('夜航船', _simple('夜航', 12)),
        ('长街', _simple('长街', 6)),
      ]) {
        final file = File('$root/$name.txt')..writeAsStringSync(text);
        expect((await library.importFiles([file.path])).single.succeeded, true);
      }
      bookId = library.books.value.firstWhere((b) => b.title == '雾港来信').id;
      for (final b in library.books.value) {
        final checks = library.openChecks(b.id);
        try {
          await checks.inspect();
        } finally {
          checks.dispose();
        }
      }
      // ATLAS_CONVERT=1：先用 Kindling 真实转出两本 EPUB，任务页、转换历史与成品验收才有内容。
      if (Platform.environment['ATLAS_CONVERT'] == '1') {
        final session = LegacyConversionSession(state);
        final plan = await session.preview(
          ConversionRequest(
            books: [
              for (final b in library.books.value)
                if (b.title != '长街') b.id,
            ],
            directory: '$root/output',
            format: 'EPUB',
            engine: Platform.environment['EASYPUB_TEST_KINDLING']!,
            generateCover: true,
            runChecks: true,
          ),
        );
        final outputs = await session.commit(plan, acknowledgeWarnings: true);
        taskId = outputs.firstWhere((o) => o.taskId != null).taskId;
      }
      library.selectBook(bookId);
    });

    final capture = GlobalKey();
    // 与书库相同：书的标识要做 URL 编码，否则路由匹配不到。
    final book = Uri.encodeComponent(bookId);
    final pages = <String, String>{
      'library': '/',
      'folders': '/folders',
      'overview': '/books/$book/overview',
      'chapters': '/books/$book/chapters',
      'checks': '/books/$book/checks',
      'cleanup': '/books/$book/cleanup',
      'information': '/books/$book/information',
      'layout': '/books/$book/layout',
      'resources': '/books/$book/resources',
      'conversion': '/conversion',
      'tasks': '/tasks',
      'history': '/history',
      'settings': '/settings',
      if (taskId != null) ...{
        'task-history': '/tasks/history',
        'task-output': '/tasks/output/${Uri.encodeComponent(taskId!)}',
      },
    };
    Future<void> settle() async {
      for (var i = 0; i < 120; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 30));
        if (i > 20 &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
      await t.pump(const Duration(milliseconds: 400));
    }

    final shots = <Map<String, Object>>[];
    for (final (width, height) in [
      (1100.0, 720.0),
      (1500.0, 950.0),
      (1900.0, 1100.0),
    ]) {
      t.view.physicalSize = Size(width, height);
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: RewriteApp(library: library, picker: _NoPicker()),
        ),
      );
      await settle();
      for (final entry in pages.entries) {
        if (only != null && !only.contains(entry.key)) continue;
        final context = t.element(find.byType(Navigator).first);
        GoRouter.of(context).go(entry.value);
        await settle();
        Future<void> shot(String page) async {
          final file = '$page-${width.toInt()}.png';
          await t.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            await File(
              '${out.path}/$file',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          });
          shots.add({
            'page': page,
            'route': entry.value,
            'width': width,
            'height': height,
            'file': file,
            'exception': '${t.takeException() ?? ''}',
          });
        }

        await shot(entry.key);
        // ATLAS_SETTINGS=1：设置页其余 6 个分区逐个点开截图（V16 起共 7 个分区）。
        if (entry.key == 'settings' &&
            Platform.environment['ATLAS_SETTINGS'] == '1') {
          const tabs = [
            '导入与收藏',
            '成品与输出',
            '自动检查',
            '转换工具',
            '数据与迁移',
            '关于与许可',
          ];
          for (var i = 0; i < tabs.length; i++) {
            await t.tap(find.text(tabs[i]).first);
            await settle();
            await shot('settings-${i + 1}');
          }
        }
      }
      await t.pumpWidget(const SizedBox());
      await settle();
    }
    await t.runAsync(() async {
      await File('${out.path}/pages.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(shots));
    });
    debugDisableShadows = true;
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    library.dispose();
    state.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
