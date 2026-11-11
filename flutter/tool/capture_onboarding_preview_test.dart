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
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';

class _Picker extends Fake implements BookFilePicker {}

void main() {
  testWidgets('真实界面中的引导卡与收起按钮预览', (t) async {
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
    final out = Directory('../design/onboarding-real-preview');
    await t.runAsync(() async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(Platform.environment['EASYPUB_TEST_DLL']!));
      await loadDeskFonts();
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
    final target = t.getRect(find.ancestor(of: find.text('导入'), matching: find.byType(DeskButton)).first);
    final overlay = Overlay.of(t.element(find.byType(LibraryPage)));
    late OverlayEntry entry;
    bool collapsed = false;
    entry = OverlayEntry(builder: (context) {
      return Stack(children: [
        if (!collapsed) Positioned.fromRect(rect: target.inflate(5), child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: const Color(0xff8d6a3b), width: 2), borderRadius: BorderRadius.circular(8))))),
        Positioned(right: 24, top: target.bottom + 18, width: collapsed ? 188 : 370,
          child: Material(color: const Color(0xfffcfbf8), elevation: collapsed ? 3 : 9, shadowColor: const Color(0x334b4439), borderRadius: BorderRadius.circular(9),
            child: Container(decoration: BoxDecoration(border: Border.all(color: const Color(0xffccc3b3)), borderRadius: BorderRadius.circular(9)),
              child: collapsed
                ? InkWell(onTap: () { collapsed = false; entry.markNeedsBuild(); }, borderRadius: BorderRadius.circular(9), child: const Padding(padding: EdgeInsets.symmetric(horizontal: 16, vertical: 13), child: Row(children: [Icon(Icons.explore_outlined, size: 19), SizedBox(width: 9), Text('新手引导', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), Spacer(), Text('1 / 4', style: TextStyle(fontSize: 12, color: Color(0xff706b62)))])))
                : Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [const Icon(Icons.explore_outlined, size: 17, color: Color(0xff706b62)), const SizedBox(width: 8), const Text('入门引导  ·  1 / 4', style: TextStyle(fontSize: 12, color: Color(0xff706b62))), const Spacer(), InkWell(onTap: () { collapsed = true; entry.markNeedsBuild(); }, child: const Padding(padding: EdgeInsets.all(5), child: Icon(Icons.remove, size: 18)))]),
                  const SizedBox(height: 14),
                  const Text('从导入一本书开始', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  const Text('点击上方「导入」，选择你的书。\n也可以直接把文件拖进书库。', style: TextStyle(fontSize: 14, height: 1.8, color: Color(0xff5e5a53))),
                  const SizedBox(height: 14),
                  const Text('已经有书？选中一本，继续下一步。', style: TextStyle(fontSize: 12, color: Color(0xff706b62))),
                  const SizedBox(height: 20),
                  Row(children: [TextButton(onPressed: () { collapsed = true; entry.markNeedsBuild(); }, child: const Text('暂不需要')), const Spacer(), FilledButton(style: FilledButton.styleFrom(backgroundColor: const Color(0xff6f6a63), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))), onPressed: () { collapsed = true; entry.markNeedsBuild(); }, child: const Text('下一步 →'))]),
                ])),
            ),
          ),
        ),
      ]);
    });
    overlay.insert(entry);
    Future<void> shot(String name) async {
      await t.pumpAndSettle();
      await t.runAsync(() async {
      final image = await (capture.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${out.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      });
    }
    await shot('01-引导卡片');
    await t.tap(find.text('暂不需要'));
    await shot('02-引导按钮');
    await t.tap(find.text('新手引导'));
    await t.pumpAndSettle();
    expect(find.text('从导入一本书开始'), findsOneWidget);
    expect(t.takeException(), isNull);
    entry.remove();
    entry.dispose();
    await t.pumpWidget(const SizedBox());
    library.dispose();
    state.dispose();
    debugDisableShadows = previousShadows;
  });
}



