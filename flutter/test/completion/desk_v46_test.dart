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

/// 读出 EPUB 内的文本成员。
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
 print(json.dumps({n:z.read(n).decode('utf-8','replace') for n in z.namelist() if n.rsplit('.',1)[-1].lower() in ('opf','xhtml','css')},ensure_ascii=False))
''',
      path,
    ],
    stdoutEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return Map<String, String>.from(jsonDecode(result.stdout as String) as Map);
}

/// V46：场景分隔（LAY-118）与导航地标（OUT-084）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('场景分隔规则与 Rust 一致：“……”“——”不算', () {
    for (final yes in [
      '***',
      '＊＊＊',
      '* * *',
      '　◇　◇　◇',
      '※※※※',
      '＝＝＝＝＝',
      '~~~',
      '☆☆☆',
    ]) {
      expect(isSceneBreak(yes), true, reason: yes);
    }
    for (final no in [
      '**',
      '……',
      '——',
      '------',
      '···',
      '',
      '***！',
      '第一章',
      '○',
      '*' * 41,
    ]) {
      expect(isSceneBreak(no), false, reason: no);
    }
    expect(sceneBreakStyles.keys, ['off', 'keep', 'stars', 'diamonds', 'line']);
    expect(sceneBreakText('keep', ' *** '), '***');
    expect(sceneBreakText('stars', '***'), '＊　＊　＊');
  });

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

  testWidgets('排版页：场景分隔默认“居中保留原符号”，点选后自动保存，问号说明识别规则', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v46-layout-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/样书.txt')
        ..writeAsStringSync('第一章 开始\n正文甲。\n＊＊＊\n正文乙。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    expect(state.production.settings(id)['scene_break_style'], 'keep');
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
    await t.tap(find.byKey(const ValueKey('layout-row-scene_break_style')));
    await t.pump();
    final control = find.byKey(const ValueKey('layout-scene_break_style'));
    await until(t, () => control.evaluate().isNotEmpty);
    final segmented = t.widget<DeskSegmented<String>>(
      find.descendant(
        of: control,
        matching: find.byType(DeskSegmented<String>),
      ),
    );
    expect(segmented.value, 'keep');
    expect(segmented.options, sceneBreakStyles);
    final help = t.widget<Tooltip>(
      find.descendant(
        of: find.byKey(const ValueKey('layout-help-scene-break')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(help.message, contains('“……”“——”单独成行仍当正文'));
    await t.ensureVisible(control);
    await t.pump();
    await t.tap(find.descendant(of: control, matching: find.text('◇　◇　◇')));
    await until(
      t,
      () => state.production.settings(id)['scene_break_style'] == 'diamonds',
    );
    expect(t.takeException(), isNull);
  });

  test('真实转换：EPUB 中场景分隔替换并保留原符号，导航含地标，OPF 含 guide', () async {
    final root = (await Directory('../artifacts').createTemp('v46-epub-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/雾港.txt')
        ..writeAsStringSync(
          '序\n引子正文。\n第一章 雾起\n正文甲。\n＊＊＊\n正文乙。\n……\n第二章 旧码头\n正文丙。\n',
        );
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
      final change = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'scene_break_style': {'op': 'set', 'value': 'stars'},
          },
        },
      });
      expect(await state.production.confirm(change), true);
      expect(state.production.settings(id)['scene_break_style'], 'stars');
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
        final results = await session.commit(plan, acknowledgeWarnings: true);
        expect(results.single.complete, true, reason: results.single.detail);
        final files = await members(results.single.path);
        final xhtml = files.entries
            .where((e) => e.key.endsWith('.xhtml'))
            .map((e) => e.value)
            .join('\n');
        expect(
          xhtml,
          contains(
            'class="scene-break" data-source="true" data-original="＊＊＊"',
          ),
        );
        expect(xhtml, contains('>＊　＊　＊</p>'));
        expect(xhtml, contains('class="text-line"'));
        expect(
          xhtml,
          contains(
            '<p class="text-line" data-source="true" data-eol="lf">　　……</p>',
          ),
          reason: '“……”仍是正文（带默认的全角缩进）',
        );
        final nav = files.entries
            .firstWhere((e) => e.key.endsWith('nav.xhtml'))
            .value;
        expect(nav, contains('epub:type="landmarks"'));
        final body = RegExp(r'epub:type="bodymatter" href="([^"]+)"')
            .firstMatch(nav)!
            .group(1)!;
        final start = files.entries
            .firstWhere((e) => e.key.endsWith('/$body'))
            .value;
        expect(start, contains('第一章 雾起'), reason: '正文开头指向第一章，不是序');
        final opf = files.entries
            .firstWhere((e) => e.key.endsWith('.opf'))
            .value;
        expect(
          opf,
          contains('<reference type="text" title="正文" href="$body"/>'),
        );
      } finally {
        session.dispose();
      }
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
