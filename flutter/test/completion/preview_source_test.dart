import 'dart:io';

import 'package:flutter/services.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/application/library_service.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class _NoPicker extends Fake implements BookFilePicker {}

void main() {
  final sample = Platform.environment['EASYPUB_LAYOUT_PROBE'];
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  testWidgets('原书预览保留章节和 CSS，模式切换不冒充小预览', (t) async {
    t.view.physicalSize = const Size(1440, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final root = Directory('../artifacts')
          .createTempSync('preview-source-')
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      expect((await library.importFiles([sample!])).single.succeeded, true);
      id = state.currentId;
      final session = library.openLayout(id);
      final original = await (session as LayoutDraftPreviewSession)
          .renderDraftPreview({'font_size': 300.0}, original: true);
      expect(
        File('${original.directory}/META-INF/container.xml').existsSync(),
        true,
      );
      final chapters = Directory('${original.directory}/OEBPS')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => RegExp(r'c\d+\.xhtml$').hasMatch(f.path))
          .toList();
      expect(chapters, hasLength(65));
      expect(
        File('${original.directory}/OEBPS/g0/style.css').readAsStringSync(),
        contains('font-size:110%'),
      );
      expect(
        File('${original.directory}/OEBPS/g3/c003.xhtml').readAsStringSync(),
        contains('orphans:3;widows:3'),
      );
      expect(
        File('${original.directory}/OEBPS/g0/c001.xhtml').readAsStringSync(),
        isNot(contains('START')),
      );
      expect(original.content, 'OEBPS/g0/c000.xhtml');
      final software = await (session as LayoutDraftPreviewSession)
          .renderDraftPreview({});
      expect(File('${software.directory}/package.opf').existsSync(), true);
      final chaptersSession = library.openChapters(id);
      final outline = await (chaptersSession as ChapterOutlineSession)
          .readOutline();
      debugPrint(
        'Original preview: ${original.directory}; software outline: ${outline.nodes.length} nodes',
      );
      session.dispose();
    });
    final changes = ValueNotifier<int>(0);
    var original = true;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: LayoutPage(
            library: library,
            bookId: id,
            navigation: LayoutNavigationGuard(),
            pickPresetFile: () async => null,
            pickPresetDestination: () async => null,
            importCss: () async => null,
            keepsOriginal: () => original,
            conversionChanges: changes,
          ),
        ),
      ),
    );
    for (var i = 0; i < 200 && find.text('当前使用原书排版').evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(find.text('当前使用原书排版'), findsOneWidget);
    expect(find.text('此章节没有可预览正文。'), findsNothing);
    original = false;
    changes.value++;
    await t.pump();
    expect(find.text('预览来源：软件排版'), findsOneWidget);
    expect(find.text('此章节没有可预览正文。'), findsNothing);
    await t.pumpWidget(const SizedBox());
    var pinned = false;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        if (call.method == 'isMaximized') return false;
        if (call.method == 'isAlwaysOnTop') return pinned;
        if (call.method == 'setAlwaysOnTop') {
          pinned = (call.arguments as Map).values.single as bool;
        }
        return null;
      },
    );
    library.selectBook(id);
    await t.pumpWidget(
      RewriteApp(
        library: library,
        picker: _NoPicker(),
        initialLocation: '/books/${Uri.encodeComponent(id)}/layout',
      ),
    );
    for (var i = 0; i < 60; i++) {
      await t.pump(const Duration(milliseconds: 30));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    final toggle = find.byKey(const ValueKey('quick-epub-layout-source'));
    expect(toggle, findsOneWidget);
    await t.tap(toggle);
    await t.pumpAndSettle();
    await t.tap(find.text('保持原书排版'));
    await t.pumpAndSettle();
    expect(find.text('当前使用原书排版'), findsOneWidget);
    await t.tap(toggle);
    await t.pumpAndSettle();
    await t.tap(find.text('使用软件排版'));
    await t.pumpAndSettle();
    expect(find.text('预览来源：软件排版'), findsOneWidget);
    await t.tap(find.byTooltip('窗口置顶（方便拖入文件）'));
    await t.pumpAndSettle();
    expect(pinned, true);
    expect(find.byTooltip('取消窗口置顶'), findsOneWidget);
    await t.tap(find.byTooltip('取消窗口置顶'));
    await t.pumpAndSettle();
    expect(pinned, false);
    t.view.physicalSize = const Size(1024, 700);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);

    await t.pumpWidget(const SizedBox());
    changes.dispose();
    library.dispose();
    state.dispose();
  }, skip: sample == null);
}
