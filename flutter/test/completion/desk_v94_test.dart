// V94 编辑台流畅度与菜单（G-077–079、LIB-190）：导航栏只高亮当前页；切换页面不播过渡动画；
// 命令菜单在按钮正下方展开、条目紧凑。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/plugin_host.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class NoPicker extends Fake implements BookFilePicker {}

bool railSelected(WidgetTester t, String label) => t
    .widget<Semantics>(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.label == label &&
            w.properties.button == true,
      ),
    )
    .properties
    .selected!;

void main() {
  testWidgets('导航栏只高亮当前页；切换页面不播过渡动画', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File(
            Platform.environment['EASYPUB_TEST_DLL'] ??
                '../target/release/easypub_bridge.dll',
          ).absolute.path,
        ),
      );
      final tmp = await Directory.systemTemp.createTemp('easypub-desk-v94-');
      final state = PrototypeState(settingsDirectory: '${tmp.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
    });
    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
      }
    }

    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    await t.pumpWidget(
      RewriteApp(library: library, picker: NoPicker(), initialLocation: '/'),
    );
    await settle();
    expect(railSelected(t, '书库'), isTrue);
    final router = GoRouter.of(
      t.element(find.byKey(const ValueKey('workspace-output-bar'))),
    );
    double entered() => ModalRoute.of(
      t.element(find.byKey(const ValueKey('workspace-output-bar'))),
    )!.animation!.value;
    for (final (path, label) in [
      ('/settings', '设置'),
      ('/plugins', '插件'),
      ('/history', '记录'),
    ]) {
      router.go(path);
      // 一帧之后新页已完全显示（原先 Windows 缩放淡入约 300ms）。
      await t.pump();
      await t.pump();
      expect(find.byType(LibraryPage), findsNothing, reason: path);
      expect(entered(), 1.0, reason: path);
      await settle();
      expect(railSelected(t, '书库'), isFalse, reason: path);
      expect(railSelected(t, label), isTrue, reason: path);
      router.go('/');
      await t.pump();
      await t.pump();
      expect(find.byType(LibraryPage), findsOne);
      expect(entered(), 1.0);
      await settle();
      expect(railSelected(t, '书库'), isTrue);
    }
    await t.pumpWidget(const SizedBox.shrink());
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });

  testWidgets('命令菜单在按钮正下方展开，条目紧凑，沿用条目 Key', (t) async {
    var picked = '';
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: DeskMenuButton<String>(
                key: const ValueKey('menu'),
                tooltip: '检查',
                onSelected: (v) => picked = v,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    key: ValueKey('menu-ping'),
                    value: 'ping',
                    child: Text('测速全部（只测能否连上）'),
                  ),
                  PopupMenuItem(value: 'check', child: Text('校验全部')),
                  PopupMenuItem(
                    enabled: false,
                    value: 'off',
                    child: Text('不可用'),
                  ),
                ],
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('检查'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final button = t.getRect(find.byKey(const ValueKey('menu')));
    // 关闭时不构造条目。
    expect(find.byKey(const ValueKey('menu-ping')), findsNothing);
    await t.tap(find.byKey(const ValueKey('menu')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    final item = t.getRect(find.byKey(const ValueKey('menu-ping')));
    expect(item.top, greaterThanOrEqualTo(button.bottom));
    expect(item.height, lessThanOrEqualTo(36));
    // 不可用的条目点了没有反应，菜单也不关。
    await t.tap(find.text('不可用'));
    await t.pump();
    expect(picked, '');
    expect(find.byKey(const ValueKey('menu-ping')), findsOne);
    // 点选后当帧就执行，不等下一帧。
    await t.tap(find.byKey(const ValueKey('menu-ping')));
    expect(picked, 'ping');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-ping')), findsNothing);
  });

  test('插件校验值按大小与修改时间缓存；改动后重新校验，启动前总是重新计算', () async {
    final root = Directory.systemTemp.createTempSync('v94-plugin-');
    addTearDown(() => root.deleteSync(recursive: true));
    final dir = Directory('${root.path}/plugins/demo')
      ..createSync(recursive: true);
    final exe = File('${dir.path}/demo.exe')
      ..writeAsBytesSync(List.filled(4096, 7));
    File('${dir.path}/plugin.json').writeAsStringSync(
      jsonEncode({
        'id': 'demo',
        'name': '演示',
        'executable': 'demo.exe',
        'sha256': sha256.convert(exe.readAsBytesSync()).toString(),
      }),
    );
    final registry = PluginRegistry(
      roots: ['${root.path}/plugins'],
      userRoot: '${root.path}/user',
      dataRoot: '${root.path}/data',
    );
    await registry.setEnabled('demo', true);
    expect(registry.isActive('demo'), isTrue);
    // 改动内容（大小变了）：不用缓存，立即判为不可用。
    exe.writeAsBytesSync(List.filled(4097, 7));
    expect(registry.isActive('demo'), isFalse);
    // 改回原内容：恢复可用。
    exe.writeAsBytesSync(List.filled(4096, 7));
    expect(registry.isActive('demo'), isTrue);
    // 同大小、改回原修改时间的篡改：列表判断沿用缓存，但启动前重新计算并拒绝。
    final stamp = exe.lastModifiedSync();
    exe.writeAsBytesSync(List.filled(4096, 8));
    exe.setLastModifiedSync(stamp);
    await expectLater(
      registry.client('demo'),
      throwsA(
        isA<PluginError>().having(
          (e) => e.message,
          'message',
          contains('校验值不符'),
        ),
      ),
    );
    // 重新计算后缓存也更新，列表随之判为不可用。
    expect(registry.isActive('demo'), isFalse);
  });
}
