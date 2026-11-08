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

/// 读出 zip 内的文本成员。
Future<Map<String, String>> members(String path) async {
  final result = await Process.run(
    Platform.environment['EASYPUB_TEST_PYTHON']!,
    [
      '-X',
      'utf8',
      '-c',
      r'''
import json,sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
 print(json.dumps({n:z.read(n).decode('utf-8','replace') for n in z.namelist() if n.rsplit('.',1)[-1].lower() in ('opf','xhtml','html','htm','css')},ensure_ascii=False))
''',
      path,
    ],
    stdoutEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return Map<String, String>.from(jsonDecode(result.stdout as String) as Map);
}

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

String ruby(String c, String py) =>
    '<ruby>$c<rp>（</rp><rt>$py</rt><rp>）</rp></ruby>';

/// V73：生僻字注音（LAY-129）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('排版页：新书默认“每章首次 · 表外字”，改为“每次”和“表外字和三级字”后自动保存', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v73-layout-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')..writeAsStringSync('第一章 开始\n城外有座龘山。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    expect(state.production.settings(id)['rare_char_ruby'], 'chapter');
    expect(state.production.settings(id)['rare_char_scope'], 'outside');
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
    final row = find.byKey(const ValueKey('layout-row-rare_char_ruby'));
    await t.ensureVisible(row);
    expect(
      find.descendant(of: row, matching: find.text('每章首次 · 表外字')),
      findsOneWidget,
    );
    await t.tap(row);
    await t.pump();
    final mode = find.byKey(const ValueKey('layout-rare_char_ruby'));
    final scope = find.byKey(const ValueKey('layout-rare_char_scope'));
    await until(t, () => mode.evaluate().isNotEmpty);
    expect(
      t
          .widget<DeskSegmented<String>>(
            find.descendant(
              of: mode,
              matching: find.byType(DeskSegmented<String>),
            ),
          )
          .options,
      rareCharRubyModes,
    );
    final help = t.widget<Tooltip>(
      find.descendant(
        of: find.byKey(const ValueKey('layout-help-rare-char')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(help.message, contains('繁体字按对应简体判断'));
    await t.ensureVisible(scope);
    await t.pump();
    await t.tap(find.descendant(of: mode, matching: find.text('每次')));
    await until(
      t,
      () => state.production.settings(id)['rare_char_ruby'] == 'every',
    );
    await t.tap(find.descendant(of: scope, matching: find.text('表外字和三级字')));
    await until(
      t,
      () => state.production.settings(id)['rare_char_scope'] == 'level3',
    );
    expect(t.takeException(), isNull);
  });

  test('真实转换：EPUB、AZW3、KFX 中生僻字带注音，标题不标，原文不改', () async {
    final root = (await Directory('../artifacts').createTemp('v73-output-'))
        .absolute
        .path;
    final bokai = Platform.environment['EASYPUB_TEST_BOKAI']!;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    Future<Map<String, String>> decode(String path, String name) async {
      final target = '$root/$name.epub';
      final run = await Process.run(
        bokai,
        ['convert', '--no-validate', path, target],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      return members(target);
    }

    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/龘山.txt')
        ..writeAsStringSync('第一章 龘山\n城外有座龘山，表情囧。\n他望着龘山。\n第二章 喆\n再回到龘山，遇见喆。\n');
      final original = file.readAsBytesSync();
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
      final outputs = <String, String>{};
      for (final format in ['EPUB', 'AZW3', 'KFX']) {
        final session = LegacyConversionSession(state);
        try {
          final plan = await session.preview(
            ConversionRequest(
              books: [id],
              directory: '$root/out',
              format: format,
              engine: switch (format) {
                'KFX' => bokai,
                'AZW3' => Platform.environment['EASYPUB_TEST_KINDLING']!,
                _ => '',
              },
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(plan.previewed, true);
          final result = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(result.complete, true, reason: '$format ${result.detail}');
          outputs[format] = result.path;
        } finally {
          session.dispose();
        }
      }
      final epub = await members(outputs['EPUB']!);
      final xhtml = epub.entries
          .where((e) => e.key.endsWith('.xhtml'))
          .map((e) => e.value)
          .join('\n');
      // 新书默认每章首次、只标表外字：两章各标一次“龘”，“囧”一次；三级字“喆”不标；标题不标。
      expect(ruby('龘', 'dá').allMatches(xhtml).length, 2);
      expect(xhtml, contains(ruby('囧', 'jiǒng')));
      expect(xhtml, isNot(contains('<rt>zhé</rt>')));
      expect(xhtml, contains('他望着龘山。'));
      expect(xhtml, isNot(contains('第一章 <ruby>')));

      final azw3 = (await decode(outputs['AZW3']!, 'azw3')).values.join('\n');
      expect(azw3, contains('<ruby'));
      expect(azw3, contains('dá'));

      // KFX 转换时已通过 Bokai 校验；解回后注音仍在。
      final kfx = (await decode(outputs['KFX']!, 'kfx')).values.join('\n');
      expect(kfx, contains('dá'));
      expect(kfx, contains('jiǒng'));
      expect(file.readAsBytesSync(), original);
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
