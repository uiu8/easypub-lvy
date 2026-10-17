import 'dart:io';

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

class _NoPicker extends Fake implements BookFilePicker {}

/// V16b：EPUB 封面页按原图比例显示（OUT-074）；设置分区（SET-062–064）；
/// 书稿概览（LIB-111、LIB-112）。真实应用、真实 Rust、真实转换。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('EPUB 封面页用 SVG 保持原图比例；AZW3 仍可转出（OUT-074）', () async {
    final root = (await Directory('../artifacts').createTemp('v16b-cover-'))
        .absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('${root.path}/龙游令.txt')
        ..writeAsStringSync('第一章 开始\n　　正文。\n第二章 结束\n　　正文。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = library.books.value.single.id;
      Future<String> convert(String format) async {
        final session = LegacyConversionSession(state);
        try {
          final plan = await session.preview(
            ConversionRequest(
              books: [id],
              directory: '${root.path}/out-$format',
              format: format,
              engine: Platform.environment['EASYPUB_TEST_KINDLING']!,
              generateCover: true,
              runChecks: false,
            ),
          );
          final output = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(output.phase, 'complete', reason: output.detail);
          return output.path;
        } finally {
          session.dispose();
        }
      }

      final epub = await convert('EPUB');
      final unpacked = Directory('${root.path}/unpacked')..createSync();
      final tar = await Process.run('tar', ['-xf', epub, '-C', unpacked.path]);
      expect(tar.exitCode, 0, reason: '${tar.stderr}');
      final files = unpacked.listSync(recursive: true).whereType<File>();
      final cover = files
          .firstWhere((f) => f.path.endsWith('cover.xhtml'))
          .readAsStringSync();
      // 生成封面是 1200 × 1600。
      expect(cover, contains('viewBox="0 0 1200 1600"'));
      // 新书默认“完整显示”（OUT-075）。
      expect(cover, contains('preserveAspectRatio="xMidYMid meet"'));
      expect(cover, isNot(contains('<img')));
      final opf = files
          .firstWhere((f) => f.path.endsWith('package.opf'))
          .readAsStringSync();
      expect(
        RegExp(r'<item [^>]*href="cover.xhtml"[^>]*properties="svg"')
            .hasMatch(opf),
        true,
      );
      final css = files
          .where((f) => f.path.endsWith('.css'))
          .map((f) => f.readAsStringSync())
          .join();
      expect(css, isNot(contains('object-fit')));
      // Kindling 的 AZW3 不把封面页放进阅读顺序，SVG 封面页不影响转出。
      expect(File(await convert('AZW3')).lengthSync(), greaterThan(0));
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  testWidgets('设置分区与概览按 V16b 显示（SET-062–064、LIB-111、LIB-112）', (t) async {
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
    late String id;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v16b-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/书.txt')
        ..writeAsStringSync('第1章 起\n　　正文。\n第3章 跳\n　　正文。\n');
      await library.importFiles([file.path]);
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
    Future<void> settle() async {
      for (var i = 0; i < 50; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 30));
      }
    }

    await t.pumpWidget(RewriteApp(library: library, picker: _NoPicker()));
    await settle();
    final router = GoRouter.of(t.element(find.byType(Navigator).first));

    // 设置：7 个分区，名称与页面标题一致（SET-062）。
    router.go('/settings');
    await settle();
    for (final name in [
      '外观与交互',
      '导入与收藏',
      '成品与输出',
      '自动检查',
      '转换工具',
      '数据与迁移',
      '关于与许可',
    ]) {
      await t.tap(find.text(name).first);
      await settle();
      // 左侧分区与右侧标题各一处。
      expect(find.text(name), findsNWidgets(2), reason: name);
      expect(t.takeException(), isNull, reason: name);
    }
    for (final gone in ['导入默认', '输出默认', '转换器', '数据与恢复', '字段来源', '配置迁移']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    // 关于与许可里有设置来源层级；数据与迁移里直接有迁移表单。
    expect(find.text('设置的来源与优先级'), findsOneWidget);
    await t.tap(find.text('数据与迁移').first);
    await settle();
    expect(find.text('迁移旧版配置'), findsOneWidget);
    expect(find.widgetWithText(TextField, '旧设置文件路径'), findsOneWidget);
    // 成品与输出：KFX 提示只在 KFX 选项下（SET-063）。
    await t.tap(find.text('成品与输出').first);
    await settle();
    expect(find.text('选择 Bokai'), findsNothing);
    expect(find.textContaining('需要 Bokai'), findsOneWidget);
    // 保存状态只在左下角一处（SET-064）。
    expect(find.byKey(const ValueKey('settings-save-status')), findsOneWidget);
    expect(find.text('设置更改后自动保存'), findsNothing);
    expect(find.text('修改立即保存'), findsNothing);

    // 概览：检查摘要并入制作进度；状态靠右；入口改为链接（LIB-111、LIB-112）。
    router.go('/books/${Uri.encodeComponent(id)}/overview');
    await settle();
    expect(find.text('检查摘要'), findsNothing);
    expect(
      t.widget<Text>(find.byKey(const ValueKey('overview-checked-at'))).data,
      startsWith('检查于 '),
    );
    expect(find.text('检查本书'), findsOneWidget);
    expect(find.text('查看全部问题'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('overview-edit-information')),
      findsOneWidget,
    );
    expect(find.text('全部记录 →'), findsOneWidget);
    final label = t.getRect(find.text('图片与资源').last);
    final detail = t.getRect(find.text('引用检查通过'));
    // 状态占行的右侧并靠右排，紧挨着箭头。
    expect(detail.right, greaterThan(label.right + 300));
    expect(
      t.widget<Text>(find.text('引用检查通过')).textAlign,
      TextAlign.right,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await settle();
  });
}
