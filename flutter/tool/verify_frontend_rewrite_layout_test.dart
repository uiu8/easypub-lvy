import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' show ApiError;
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/layout/layout_presets_dialog.dart';
import 'package:easypub_desktop/desk/layout/css_dialog.dart';
import 'package:easypub_desktop/infrastructure/css_file_reader.dart';

class _Picker implements BookFilePicker {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('layout real body, automatic application, validation and recovery', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
    final dir = Directory('../artifacts/frontend-rewrite/layout-probe');
    final source = File('${dir.path}/排版样书.txt');
    const original =
        '第一章 夜渡\n夜色落在河面上，渡口只剩下一盏灯。\n'
        '船夫没有催促，只把缆绳轻轻绕在木桩上。\n第二章 来信\n远方来了信。\n';
    final backend = PrototypeState(
      settingsDirectory: '${dir.absolute.path}/settings',
    );
    addTearDown(backend.dispose);
    await tester.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File('../target/release/easypub_bridge.dll').absolute.path,
        ),
      );
      await dir.create(recursive: true);
      await source.writeAsString(original);
      for (final entry in {
        'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
        'Consolas': 'C:/Windows/Fonts/consola.ttf',
        'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(entry.key)..addFont(
              File(entry.value)
                  .readAsBytes()
                  .then((bytes) => bytes.buffer.asByteData()),
            ))
            .load();
      }
      await backend.importBookOutcome(source.absolute.path);
    });
    final library = LegacyLibraryAdapter(backend: backend);
    addTearDown(library.dispose);
    final id = backend.currentId;
    await tester.runAsync(() async {
      final layout = library.openLayout(id);
      await layout.apply(
        await layout.preview({'font_size': 18, 'font_size_unit': 'px'}),
      );
      layout.dispose();
    });
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: RewriteApp(library: library, picker: _Picker()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('排版').first);
    await tester.pump();
    Future<void> waitFor(bool Function() ready) async {
      for (var i = 0; i < 200 && !ready(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(ready(), true);
      await tester.pumpAndSettle();
    }

    await waitFor(
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    expect(find.textContaining('夜色落在河面上', findRichText: true), findsOneWidget);
    final field = find.byKey(const ValueKey('layout-font_size'));
    final originalLineOrigin =
        (backend.production.settings(id)['layout_origins']
            as Map?)?['line_height'];
    final settingsFieldBeforeTyping = tester.widget<TextField>(field);
    await tester.enterText(field, '20');
    await tester.pump();
    expect(
      identical(tester.widget<TextField>(field), settingsFieldBeforeTyping),
      isTrue,
      reason:
          'Typing must update the preview without rebuilding the settings form',
    );
    final previewText = tester.widget<RichText>(
      find.textContaining('夜色落在河面上', findRichText: true),
    );
    expect(previewText.text.style!.fontSize, 20);
    expect(backend.production.settings(id)['font_size'], 18);
    await tester.pump(const Duration(milliseconds: 500));
    await waitFor(() => backend.production.settings(id)['font_size'] == 20);
    expect(find.text('确认排版变更'), findsNothing);
    expect(backend.production.settings(id)['font_size'], 20);
    expect(
      (backend.production.settings(id)['layout_origins'] as Map)['line_height'],
      originalLineOrigin,
    );
    await tester.enterText(field, 'not-a-number');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('输入已暂存；数字补全后自动应用。'), findsOneWidget);
    expect(backend.production.settings(id)['font_size'], 20);
    expect(library.readDraft('layout:$id')?['font_size'], 'not-a-number');
    await tester.tap(find.text('撤销未应用输入'));
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.text('预设库 / 另存为预设'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('layout-preset-name')),
      'Kindle 正文',
    );
    await tester.tap(find.text('另存为预设'));
    await tester.pump();
    await waitFor(
      () => find.text('已加入本项目；保存项目后保留。书籍设置未改动。').evaluate().isNotEmpty,
    );
    expect(backend.production.settings(id)['font_size'], 20);
    expect(backend.layoutPresets.single['name'], 'Kindle 正文');
    await tester.enterText(
      find.byKey(const ValueKey('layout-preset-name')),
      'kindle 正文',
    );
    await tester.tap(find.text('另存为预设'));
    await tester.pump();
    await waitFor(() => find.text('名称无效、重复或已达64项上限。').evaluate().isNotEmpty);
    expect(backend.layoutPresets.length, 1);
    await tester.enterText(
      find.byKey(const ValueKey('layout-preset-name')),
      'Kindle 正文改名',
    );
    await tester.tap(find.text('重命名为输入名称'));
    await tester.pump();
    await waitFor(
      () => find.text('预设已重命名；已有书籍的历史来源名称保留。').evaluate().isNotEmpty,
    );
    expect(backend.layoutPresets.single['name'], 'Kindle 正文改名');
    await tester.enterText(
      find.byKey(const ValueKey('layout-preset-name')),
      'Kindle 正文',
    );
    await tester.tap(find.text('重命名为输入名称'));
    await tester.pump();
    await waitFor(() => backend.layoutPresets.single['name'] == 'Kindle 正文');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置来源 / 恢复默认'));
    await tester.pumpAndSettle();
    expect(find.text('排版设置来源'), findsOneWidget);
    expect(find.textContaining('本书覆盖'), findsWidgets);
    final fontOrigin =
        (backend.production.settings(id)['layout_origins'] as Map)['font_size']
            as Map;
    expect(fontOrigin['source'], 'book');
    expect(fontOrigin['value'], 20);
    await tester.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${dir.path}/layout-origins.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    final fontCheckbox = find.descendant(
      of: find.widgetWithText(Row, '字号'),
      matching: find.byType(Checkbox),
    );
    await tester.tap(fontCheckbox);
    await tester.pump();
    expect(tester.widget<Checkbox>(fontCheckbox).value, true);
    await tester.tap(find.text('预览并确认'));
    await tester.pump();
    await waitFor(() => find.text('确认按字段恢复').evaluate().isNotEmpty);
    expect(backend.production.settings(id)['font_size'], 20);
    await tester.tap(find.text('返回选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览并确认'));
    await tester.pump();
    await waitFor(() => find.text('确认按字段恢复').evaluate().isNotEmpty);
    await tester.tap(find.text('确认恢复'));
    await tester.pump();
    await waitFor(() => find.text('选定排版字段已恢复默认。').evaluate().isNotEmpty);
    expect(backend.production.settings(id)['font_size'], 110);
    expect(backend.production.settings(id)['font_size_unit'], '%');
    expect(
      (backend.production.settings(id)['layout_origins']
          as Map)['font_size']['source'],
      'restored_factory',
    );
    await tester.tap(find.text('预设库 / 另存为预设'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kindle 正文'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${dir.path}/presets.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.tap(find.text('预览并确认'));
    await tester.pump();
    await waitFor(() => find.text('应用排版预设').evaluate().isNotEmpty);
    expect(backend.production.settings(id)['font_size'], 110);
    await tester.tap(find.text('确认应用'));
    await tester.pump();
    await waitFor(() => find.text('预设已应用到本书。').evaluate().isNotEmpty);
    expect(backend.production.settings(id)['font_size'], 20);
    expect(
      (backend.production.settings(id)['layout_origins']
          as Map)['font_size']['preset_name'],
      'Kindle 正文',
    );
    await tester.ensureVisible(find.text('附加 CSS'));
    await tester.tap(find.text('附加 CSS'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('css-code-editor')),
        matching: find.byType(TextField),
      ),
      'p {\n  text-indent: 2em;\n  line-height: 1.8;\n}\nh1 { page-break-before: always; }',
    );
    await tester.tap(find.text('检查依赖'));
    await tester.pump();
    await waitFor(() => find.textContaining('依赖检查通过').evaluate().isNotEmpty);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${dir.path}/css.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.tap(find.text('放弃未应用内容'));
    await tester.pumpAndSettle();
    expect(backend.production.settings(id)['additional_css'], '');
    await tester.ensureVisible(field);
    await tester.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${dir.path}/layout.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      final session = library.openLayout(id);
      await expectLater(
        session.preview({'font_size': 200}),
        throwsA(isA<ApiError>()),
      );
      final plan = await session.preview({'font_size': 22});
      backend.change(() => backend.draft.lineHeight = 1.9);
      await expectLater(session.apply(plan), throwsA(isA<FormatException>()));
      expect(backend.production.settings(id)['font_size'], 20);
      session.saved;
      final changed = await session.preview({
        'font_size': 22,
        'margin_left': 1.2,
        'margin_left_unit': 'em',
        'visible_toc': true,
      });
      await session.apply(changed);
      final project =
          '${dir.absolute.path}/layout-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
      expect((await library.saveProject(project)).succeeded, true);
      expect((await library.openProject(project)).succeeded, true);
      expect(backend.production.settings(id)['font_size'], 22);
      expect(backend.production.settings(id)['margin_left'], 1.2);
      expect(backend.production.settings(id)['visible_toc'], true);
      final reopened = library.openLayout(id);
      expect(reopened.presets.single.name, 'Kindle 正文');
      final obsolete = await reopened.previewPreset('Kindle 正文');
      reopened.deletePreset('Kindle 正文');
      await expectLater(
        reopened.apply(obsolete),
        throwsA(isA<FormatException>()),
      );
      expect(reopened.presets, isEmpty);
      expect(backend.production.settings(id)['font_size'], 22);
      final globalName = '跨项目-${DateTime.now().microsecondsSinceEpoch}';
      await reopened.savePreset(globalName, reopened.saved);
      await reopened.readGlobalPresets();
      await reopened.publishPreset(globalName);
      expect(
        (await reopened.readGlobalPresets()).any((p) => p.name == globalName),
        true,
      );
      final externalName = '$globalName-external';
      expect(
        await backend.saveGlobalPresets([
          ...(backend.globalConfiguration['layout_presets'] as List)
              .cast<Map<String, dynamic>>(),
          {
            'name': externalName,
            'values': {'font_size': 21},
          },
        ], backend.globalSettingsToken),
        true,
      );
      await expectLater(
        reopened.deleteGlobalPreset(globalName),
        throwsA(isA<FormatException>()),
      );
      await reopened.readGlobalPresets();
      await reopened.deleteGlobalPreset(externalName);
      await reopened.readGlobalPresets();
      reopened.deletePreset(globalName);
      await reopened.copyGlobalPreset(globalName);
      expect(reopened.presets.single.name, globalName);
      await reopened.deleteGlobalPreset(globalName);
      expect(reopened.presets.single.name, globalName);
      expect(backend.production.settings(id)['font_size'], 22);
      final exportPath =
          '${dir.absolute.path}/presets-${DateTime.now().microsecondsSinceEpoch}.json';
      await reopened.exportPresetFile(globalName, exportPath);
      final exportBytes = await File(exportPath).readAsBytes();
      await expectLater(
        reopened.exportPresetFile(globalName, exportPath),
        throwsA(isA<ApiError>()),
      );
      expect(await File(exportPath).readAsBytes(), exportBytes);
      final imported = await reopened.readPresetFile(exportPath);
      expect(imported.single.name, globalName);
      await expectLater(
        reopened.importPreset(imported.single),
        throwsA(isA<FormatException>()),
      );
      reopened.deletePreset(globalName);
      await reopened.importPreset(imported.single);
      expect(reopened.presets.single.values['font_size'], 22);
      final builtIn = await reopened.builtinPreset();
      expect(builtIn.name, '出厂默认');
      expect(builtIn.values['font_size'], 110);
      expect(builtIn.values['font_size_unit'], '%');
      expect(backend.production.settings(id)['font_size'], 22);
      final badFile = File('$exportPath.bad.json');
      await badFile.writeAsString('{"schema_version":999}');
      await expectLater(
        reopened.readPresetFile(badFile.path),
        throwsA(isA<ApiError>()),
      );
      expect(reopened.presets.length, 1);
      reopened.deletePreset(globalName);
      await reopened.importPreset(builtIn);
      expect(backend.production.settings(id)['font_size'], 22);
      final builtinPlan = await reopened.previewPreset(builtIn.name);
      expect(backend.production.settings(id)['font_size'], 22);
      await reopened.apply(builtinPlan);
      expect(backend.production.settings(id)['font_size'], 110);
      reopened.deletePreset(builtIn.name);
      final cssFile = File('$exportPath.css');
      await cssFile.writeAsString('p { line-height: 1.7; }');
      final loadedCss = await readCssFile(cssFile.path);
      expect(loadedCss.text, 'p { line-height: 1.7; }');
      final missing = await reopened.previewCss(
        '@import "missing.css";',
        loadedCss.base,
      );
      expect(missing.issues, isNotEmpty);
      await expectLater(
        reopened.applyCss(missing),
        throwsA(isA<FormatException>()),
      );
      expect(reopened.savedCss['text'], '');
      final reference = '@import "${cssFile.uri.pathSegments.last}";';
      final cssPlan = await reopened.previewCss(reference, loadedCss.base);
      expect(cssPlan.issues, isEmpty);
      expect(cssPlan.files, hasLength(1));
      await cssFile.writeAsString('p { line-height: 1.9; }');
      await expectLater(
        reopened.applyCss(cssPlan),
        throwsA(isA<FormatException>()),
      );
      expect(reopened.savedCss['text'], '');
      final cssConfirmed = await reopened.previewCss(reference, loadedCss.base);
      await reopened.applyCss(cssConfirmed);
      expect(reopened.savedCss['text'], reference);
      final cssResources = library.openResources(id);
      final cssInventory = await cssResources.read();
      expect(
        cssInventory.singleWhere((r) => r.kind == 'css').byteLength,
        greaterThan(0),
      );
      expect(
        cssInventory.where((r) => r.kind == 'css-dependency'),
        hasLength(1),
      );
      expect(cssInventory.where((r) => r.kind == 'css-issue'), isEmpty);
      cssResources.dispose();
      expect(
        await backend.saveProjectOutcome('$exportPath.easypub.json'),
        true,
        reason: backend.projectStatus,
      );
      expect(
        await backend.openProjectOutcome('$exportPath.easypub.json'),
        true,
      );
      final afterCssReopen = library.openLayout(backend.currentId);
      expect(afterCssReopen.savedCss['text'], reference);
      afterCssReopen.dispose();
      await cssFile.writeAsBytes(List.filled(262145, 32));
      await expectLater(
        readCssFile(cssFile.path),
        throwsA(isA<FormatException>()),
      );
      await cssFile.writeAsString('p { line-height: 1.9; }');
      reopened.dispose();
      expect(await source.readAsString(), original);
      session.dispose();
    });
    final presetSession = library.openLayout(id);
    addTearDown(presetSession.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: LayoutPresetsDialog(
          session: presetSession,
          values: presetSession.saved,
          allowApply: true,
          label: (key) => key,
          valueText: (key, value) => '$value',
          pickFile: () async => null,
          pickDestination: () async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('内置'));
    await tester.pump();
    await waitFor(() => find.text('出厂默认').evaluate().isNotEmpty);
    await tester.tap(find.text('出厂默认'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制到本项目'));
    await tester.pump();
    await waitFor(() => presetSession.presets.isNotEmpty);
    expect(find.text('已复制到本项目；应用到书籍仍需预览确认。'), findsOneWidget);
    expect(backend.production.settings(id)['font_size'], 110);
    await tester.tap(find.text('导入文件'));
    await tester.pumpAndSettle();
    expect(presetSession.presets.single.name, '出厂默认');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => CssDialog(
                session: presetSession,
                importFile: () async =>
                    (text: 'p { text-indent: 2em; }', base: dir.absolute.path),
              ),
            ),
            child: const Text('打开CSS测试'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开CSS测试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入 CSS'));
    await tester.pumpAndSettle();
    final longEditor = find.descendant(
      of: find.byKey(const ValueKey('css-code-editor')),
      matching: find.byType(TextField),
    );
    final longCss = List.generate(
      300,
      (i) => '/* 行 ${i + 1} */ p { text-indent: 2em; }',
    ).join('\n');
    await tester.enterText(longEditor, longCss);
    await tester.pumpAndSettle();
    final editorScroll = tester.widget<TextField>(longEditor).scrollController!;
    editorScroll.jumpTo(0);
    await tester.pump();
    await tester.drag(longEditor, const Offset(0, -110));
    await tester.pumpAndSettle();
    expect(editorScroll.offset, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.enterText(longEditor, 'p { text-indent: 2em; }');
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查依赖'));
    await tester.pump();
    await waitFor(() => find.textContaining('依赖检查通过').evaluate().isNotEmpty);
    final cssEditor = find.descendant(
      of: find.byKey(const ValueKey('css-code-editor')),
      matching: find.byType(TextField),
    );
    await tester.enterText(cssEditor, '@import "absent.css";');
    await tester.pump();
    expect(find.textContaining('依赖检查通过'), findsNothing);
    await tester.tap(find.text('检查依赖'));
    await tester.pump();
    await waitFor(() => find.textContaining('不能保存').evaluate().isNotEmpty);
    await tester.enterText(cssEditor, 'p { text-indent: 2em; }');
    await tester.tap(find.text('检查依赖'));
    await tester.pump();
    await waitFor(() => find.textContaining('依赖检查通过').evaluate().isNotEmpty);
    await tester.tap(find.text('确认保存'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('确认 CSS 变更'), findsOneWidget);
    await tester.tap(find.text('返回编辑'));
    await tester.pumpAndSettle();
    expect(
      backend.production.settings(id)['additional_css'],
      isNot('p { text-indent: 2em; }'),
    );
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存 CSS'));
    await tester.pump();
    await waitFor(
      () =>
          backend.production.settings(id)['additional_css'] ==
          'p { text-indent: 2em; }',
    );
    expect(find.byType(CssDialog), findsNothing);
    expect(presetSession.savedCss['text'], 'p { text-indent: 2em; }');
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
