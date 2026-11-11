// 设计预览：正式 RewriteApp + 隔离 Rust 书库，只在测试 Overlay 中增加引导。
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';

class _Picker extends Fake implements BookFilePicker {}

void main() {
  testWidgets('真实排版单位切换与保存预览', (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final previousShadows = debugDisableShadows;
    addTearDown(() => debugDisableShadows = previousShadows);
    debugDisableShadows = false;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    final out = Directory('../design/typesetting-units-preview');
    await t.runAsync(() async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(Platform.environment['EASYPUB_TEST_DLL']!));
      await loadDeskFonts();
      await (FontLoader('Ahem')..addFont(File('C:/Windows/Fonts/msyh.ttc').readAsBytes().then((b) => ByteData.sublistView(b)))).load();
      await (FontLoader('MaterialIcons')..addFont(File('D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytes().then((b) => ByteData.sublistView(b)))).load();
      out.createSync(recursive: true);
      final temp = await Directory('../artifacts').createTemp('onboarding-preview-');
      state = PrototypeState(settingsDirectory: '${temp.absolute.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('${temp.absolute.path}/山海之间.txt');
      await file.writeAsString('山海之间\n作者：演示作者\n第一章 远行\n清晨，山间的雾还未散去。他沿着石阶走下山，听见远处传来钟声。\n第二章 来信\n桌上放着一封信，信里写着故乡的消息。\n第三章 归途\n沿着来时的路，他们又一次经过山口。\n');
      await library.importFiles([file.path]);
      library.selectBook(library.books.value.first.id);
    });
    final capture = GlobalKey();
    await t.pumpWidget(RepaintBoundary(key: capture, child: RewriteApp(library: library, picker: _Picker())));
    for (var i = 0; i < 150; i++) {
      await t.pump(const Duration(milliseconds: 40));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(find.byType(LibraryPage), findsOneWidget);
    await t.tap(find.text('排版').first);
    for(var i=0;i<100;i++) {
      await t.pump(const Duration(milliseconds:40));
      await t.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:10)));
    }
    expect(find.byType(LayoutPage),findsOneWidget);
    final unit=find.descendant(of:find.byKey(const ValueKey('layout-font_size_unit')),matching:find.byType(DeskChoice<String>));
    await t.tap(unit);
    await t.pumpAndSettle();
    await t.tap(find.text('pt').last);
    for(var i=0;i<100;i++) {
      await t.pump(const Duration(milliseconds:40));
      await t.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:10)));
    }
    expect(state.production.settings(state.currentId)['font_size_unit'],'pt');
    expect(state.production.settings(state.currentId)['layout_units_version'],1);
    expect(t.takeException(),isNull);
    final lineUnit=find.descendant(of:find.byKey(const ValueKey('layout-line_height_unit')),matching:find.byType(DeskChoice<String>));
    await t.tap(lineUnit);
    await t.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNWidgets(5));
    expect(t.takeException(), isNull);
    await t.runAsync(() async {
      final image=await (capture.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
      final bytes=await image.toByteData(format:ui.ImageByteFormat.png);
      await File('${out.path}/02-统一单位菜单.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await t.pumpWidget(const SizedBox());
    library.dispose();
    state.dispose();
    debugDisableShadows = previousShadows;
  });
}



