import 'dart:io';

import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoPicker extends Fake implements BookFilePicker {}

/// V110：收藏夹栏默认收起；列表视图的“格式、大小”两列按整个列表的宽度统一决定。
/// 用户截图（窗口约 1260 逻辑像素宽、收藏夹栏展开、11 本书）里表头有这两列、各行没有：
/// 表头和行以前各自按自己的宽度判断，真实程序里两者的内边距不同。
void main() {
  testWidgets('收藏夹栏默认收起；真实程序里表头与各行的格式、大小列一致', (t) async {
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    t.view.devicePixelRatio = 1;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    late LegacyLibraryAdapter library;
    late PrototypeState state;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final tmp = (await Directory('../artifacts').createTemp('v110-library-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$tmp/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      await library.importFiles([
        for (var i = 0; i < 14; i++)
          (File(
            '$tmp/样书$i - 作者$i.txt',
          )..writeAsStringSync('第一章 开始\n正文$i\n')).path,
      ]);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> settle([int n = 30]) async {
      for (var i = 0; i < n; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await t.pump(const Duration(milliseconds: 20));
      }
    }

    t.view.physicalSize = const Size(1260, 797);
    await t.pumpWidget(RewriteApp(library: library, picker: _NoPicker()));
    await settle(60);
    // 没有保存过的视图状态时，收藏夹栏收起。
    expect(find.byKey(const ValueKey('library-rail')), findsNothing);
    await t.tap(find.byKey(const ValueKey('library-view-toggle')));
    await t.tap(find.byKey(const ValueKey('library-rail-toggle')));
    await settle();
    expect(find.byKey(const ValueKey('library-rail')), findsOne);

    final header = find.descendant(
      of: find.byKey(const ValueKey('library-column-header')),
      matching: find.text('格式'),
    );
    for (var width = 1100.0; width <= 1500; width += 8) {
      t.view.physicalSize = Size(width, 797);
      await settle(3);
      expect(
        header.evaluate().isNotEmpty,
        find.text('TXT').evaluate().isNotEmpty,
        reason: '窗口宽 $width：表头与行要么都有格式列，要么都没有',
      );
    }
    t.view.physicalSize = const Size(1260, 797);
    await settle(3);
    expect(header, findsOne);
    expect(find.text('TXT'), findsWidgets);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
