import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/storage_locations.dart';
import 'package:easypub_desktop/desk/app/storage_rescue.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/settings/storage_settings.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

/// V104：设置 · 存储位置（SET-108–112），用真实后端与隔离的临时目录。
void main() {
  testWidgets('存储位置：显示位置与占用、清理缓存、切换图片方式与缓存位置、搬家后提示重启', (t) async {
    t.view.physicalSize = const Size(1100, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late Directory root;
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      root = await Directory.systemTemp.createTemp('easypub-v104-ui-');
      await StorageLocations.initialize(
        local: '${root.path}/local',
        temp: '${root.path}/temp',
      );
      state = PrototypeState(
        settingsDirectory: StorageLocations.directory('settings'),
      );
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      // 一份可清理的预览缓存。
      final preview = Directory(StorageLocations.directory('content_preview'));
      await preview.create(recursive: true);
      await File('${preview.path}/old.xhtml').writeAsString('x' * 4096);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final folders = <String>[];
    var restarted = 0;
    Future<void> until(bool Function() ready, String what) async {
      for (var i = 0; i < 600; i++) {
        await t.pump(const Duration(milliseconds: 20));
        if (ready()) return;
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      fail('未就绪：$what');
    }

    Finder key(String k) => find.byKey(ValueKey(k));
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: StorageSettingsGroup(
              service: library,
              chooseFolder: () async =>
                  folders.isEmpty ? null : folders.removeAt(0),
              restart: () async {
                restarted++;
                return null;
              },
              pollInterval: const Duration(milliseconds: 20),
            ),
          ),
        ),
      ),
    );
    await until(() => key('storage-data-root').evaluate().isNotEmpty, '读出位置');
    expect(
      find.descendant(
        of: key('storage-data-root'),
        matching: find.textContaining('local'),
      ),
      findsOneWidget,
    );
    expect(find.text('分散在默认位置（兼容旧版）'), findsOneWidget);
    expect(
      find.descendant(
        of: key('storage-cache-content_preview'),
        matching: find.text('4 KB'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: key('storage-cache-imports'),
        matching: find.text('保留 · 书库可能在引用'),
      ),
      findsOneWidget,
    );

    // 清理：先确认，清掉后数字归零。
    await t.tap(key('storage-clean'));
    await t.pumpAndSettle();
    expect(find.textContaining('实际生成预览'), findsWidgets);
    await t.tap(key('storage-confirm'));
    await until(() => key('storage-notice').evaluate().isNotEmpty, '清理结果');
    expect(find.textContaining('已清理 4 KB'), findsOneWidget);
    await until(
      () => find.text('没有可清理的').evaluate().isNotEmpty,
      '清理后重新统计',
    );

    // 图片方式改为只记原路径。
    await t.tap(
      find.descendant(
        of: key('storage-image-mode'),
        matching: find.text('只记原路径'),
      ),
    );
    await until(
      () => StorageLocations.layout['image_mode'] == 'reference',
      '图片方式',
    );

    // 缓存改到新位置。
    folders.add('${root.path}/cache');
    await t.tap(key('storage-cache-choose'));
    await until(
      () => find.textContaining('缓存改放到').evaluate().isNotEmpty,
      '缓存位置',
    );
    expect(
      find.descendant(
        of: key('storage-cache-root'),
        matching: find.textContaining('cache'),
      ),
      findsWidgets,
    );

    // 搬家：选空文件夹，确认后复制核对，完成后提示重启。
    final target = Directory('${root.path}/moved')..createSync();
    folders.add(target.path);
    await t.tap(key('storage-move'));
    await t.pumpAndSettle();
    expect(find.textContaining('目标文件夹必须是空的'), findsOneWidget);
    await t.tap(key('storage-confirm'));
    await until(
      () => key('storage-pending-restart').evaluate().isNotEmpty,
      '待重启提示',
    );
    expect(find.textContaining('重启后生效'), findsWidgets);
    expect(key('storage-error'), findsNothing);
    // 待重启时不能再搬一次。
    expect(t.widget<DeskButton>(key('storage-move')).onPressed, isNull);
    await t.tap(key('storage-restart'));
    await t.pump();
    expect(restarted, 1);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('读不出位置记录时只显示救援页', (t) async {
    var exited = 0;
    await t.pumpWidget(
      StorageRescueApp(
        error: const StorageException('storage_invalid_config'),
        pointerFolder: r'C:\Users\someone\AppData\Local\EasyPub-RustFlutter',
        onExit: () => exited++,
      ),
    );
    expect(find.text('没能读到软件数据的位置'), findsOneWidget);
    expect(find.textContaining('记录数据位置的文件损坏了'), findsOneWidget);
    expect(find.textContaining('没有打开工作区'), findsOneWidget);
    await t.tap(find.text('退出'));
    expect(exited, 1);
  });
}
