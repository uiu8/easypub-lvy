import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/widgets.dart';

Future<String> xhtmlOf(String path) async {
  final result = await Process.run(
    Platform.environment['EASYPUB_TEST_PYTHON']!,
    [
      '-X',
      'utf8',
      '-c',
      r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
 print('\n'.join(z.read(n).decode('utf-8') for n in z.namelist() if n.endswith('.xhtml')))
''',
      path,
    ],
    stdoutEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return result.stdout as String;
}

/// V51：排版页“弹出注释”开关（LAY-120 界面）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  Future<void> until(WidgetTester t, bool Function() ready) async {
    for (var i = 0; i < 600; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (ready()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    fail('界面未就绪');
  }

  testWidgets('排版页：弹出注释默认关闭，点选后自动保存，转换出的 EPUB 带注释链接', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String root;
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp('v51-notes-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/注释.txt')
        ..writeAsStringSync('第一章 雾港\n港口的雾①起来了。\n①雾：水汽凝结成的小水滴。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    expect(state.production.settings(id)['note_style'], 'off');
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
          ),
        ),
      ),
    );
    final tabs = find.byKey(const ValueKey('layout-tabs'));
    await until(t, () => tabs.evaluate().isNotEmpty);
    await t.tap(find.descendant(of: tabs, matching: find.text('段落与识别')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('layout-row-note_style')));
    await t.pump();
    final control = find.byKey(const ValueKey('layout-note_style'));
    await until(t, () => control.evaluate().isNotEmpty);
    final segmented = t.widget<DeskSegmented<String>>(
      find.descendant(
        of: control,
        matching: find.byType(DeskSegmented<String>),
      ),
    );
    expect(segmented.value, 'off');
    expect(segmented.options, noteStyles);
    final help = t.widget<Tooltip>(
      find.descendant(
        of: find.byKey(const ValueKey('layout-help-note_style')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(help.message, contains('AZW3、KFX 在 Kindle 上显示为弹窗'));
    expect(help.message, contains('不成对、重复或跨章的原样保留'));
    await t.ensureVisible(control);
    await t.pump();
    await t.tap(find.descendant(of: control, matching: find.text('弹出注释')));
    await until(
      t,
      () => state.production.settings(id)['note_style'] == 'popup',
    );
    expect(t.takeException(), isNull);

    await t.runAsync(() async {
      final session = LegacyConversionSession(state);
      try {
        final plan = await session.preview(
          ConversionRequest(
            books: [id],
            directory: '$root/out',
            format: 'EPUB',
            runChecks: false,
          ),
        );
        final result = (await session.commit(
          plan,
          acknowledgeWarnings: true,
        )).single;
        expect(result.complete, true, reason: result.detail);
        final xhtml = await xhtmlOf(result.path);
        expect(xhtml, contains('epub:type="noteref"'));
        expect(xhtml, contains('<aside epub:type="footnote"'));
      } finally {
        session.dispose();
      }
    });
  });
}
