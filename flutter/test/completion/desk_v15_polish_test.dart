import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/dialogs.dart';
import 'package:easypub_desktop/desk/errors.dart';

class _NoPicker extends Fake implements BookFilePicker {}

/// V15：错误原因对照表、统一弹窗、设置页构建期报错、显示缺陷。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('错误原因对照表：真实后端错误换成具体说明，未知错误附错误代码（G-065）', () async {
    Object? error;
    try {
      await api.inspectImageText(path: '');
    } catch (e) {
      error = e;
    }
    expect(error, isA<api.ApiError>());
    // 同步读取，不必在 catch 里改成异步。
    expect(
      deskErrorText(error!, '兜底'),
      deskErrorReason('choose_readable_supported_image'),
    );
    expect(deskErrorText(const FormatException('具体原因'), '兜底'), '具体原因');
    expect(
      deskErrorText(
        const FileSystemException('x', 'p', OSError('拒绝访问', 5)),
        '没有写入',
      ),
      '没有写入（系统提示：拒绝访问）',
    );
    expect(deskErrorText(StateError('内部'), '没有完成'), '没有完成');
    // 对照表覆盖了常见的书稿、清理、转换错误。
    for (final action in [
      'review_effective_nodes_and_base',
      'reduce_edit_batch',
      'cleanup_would_remove_structural_heading',
      'choose_writable_output',
      'review_production_fields',
    ]) {
      expect(deskErrorReason(action), isNotNull, reason: action);
    }
  });

  testWidgets('统一弹窗：DeskAlert 与 DeskDialog 外框一致，宽度随内容、按钮在底部（G-064）', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => DeskAlert(
                title: const Text('确认恢复设置'),
                content: const SizedBox(width: 520, child: Text('说明文字')),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开'));
    await t.pumpAndSettle();
    expect(find.text('确认恢复设置'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    final frame = t.getRect(find.byType(DeskAlert));
    expect(
      t.getRect(find.text('取消')).top,
      greaterThan(t.getRect(find.text('说明文字')).bottom),
    );
    expect(frame.width, greaterThanOrEqualTo(520));
    // 没有额外的关闭按钮：需要明确选择的确认框行为不变。
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(find.byType(DeskAlert), findsNothing);
  });

  testWidgets('从变更记录进入设置页不再在构建期间报错（SET-061）', (t) async {
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
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v15-settings-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      final file = File('$root/书.txt')..writeAsStringSync('第一章 开始\n正文\n');
      await library.importFiles([file.path]);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 30));
      }
    }

    await t.pumpWidget(RewriteApp(library: library, picker: _NoPicker()));
    await settle();
    final router = GoRouter.of(t.element(find.byType(Navigator).first));
    router.go('/history');
    await settle();
    expect(t.takeException(), isNull);
    router.go('/settings');
    await settle();
    expect(t.takeException(), isNull);
    expect(find.text('外观与交互'), findsWidgets);
    await t.pumpWidget(const SizedBox());
    await settle();
  });
}
