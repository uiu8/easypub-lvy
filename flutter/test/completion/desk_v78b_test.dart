import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/block_annotation_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/chapters/block_marks.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/block_style_editor.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';

const sample =
    '第一章 开始\n≮任务：清剿妖兽≯\n≮奖励：100灵币≯\n正文。\n【单行却要面板】\n正文二。\n'
    '【甲：一】\n【乙：二】\n结尾。\n';

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

Future<(PrototypeState, LegacyLibraryAdapter, String, String)> book(
  String tag,
) async {
  final root = (await Directory('../artifacts').createTemp('v78b-$tag-'))
      .absolute
      .path;
  final state = PrototypeState(settingsDirectory: '$root/settings');
  final library = LegacyLibraryAdapter(backend: state);
  await library.load();
  await library.savePatch({'check_after_import': false});
  final file = File('$root/系统流.txt')..writeAsStringSync(sample);
  expect((await library.importFiles([file.path])).single.succeeded, true);
  return (state, library, root, state.currentId);
}

/// V78b：系统提示自定义识别与手工指定样式（LAY-134）；每个样式参数取值的 KFX 校验。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('规则显示与整行匹配', () {
    expect(systemPatternLabel('≮.+≯'), '≮……≯');
    expect(systemPatternLabel(r'\[.+\]'), '[……]');
    expect(systemPatternLabel('叮.*'), '正则：叮.*');
    expect(systemPatternRegExp('≮.+≯')!.hasMatch('≮任务≯'), true);
    expect(systemPatternRegExp('≮.+≯')!.hasMatch('他说≮任务≯'), false);
    expect(systemPatternRegExp('('), isNull);
    expect(blockMarkLabel(BlockAnnotationKind.system, 'panel'), '系统提示 · 面板');
    expect(blockMarkKey(BlockAnnotationKind.system, null), 'system');
    expect(blockMarkKey(BlockAnnotationKind.system, 'note'), 'system-note');
  });

  testWidgets('排版页：添加括号对识别规则（试一试），删除', (t) async {
    t.view.physicalSize = const Size(1100, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final made = await book('layout');
      (state, library, _, id) = made;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
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
    List? patterns() =>
        (state.production.settings(id)['rule_options']
                as Map?)?['system_patterns']
            as List?;
    final tabs = find.byKey(const ValueKey('layout-tabs'));
    await until(t, () => tabs.evaluate().isNotEmpty);
    await t.tap(find.descendant(of: tabs, matching: find.text('段落与识别')));
    await t.pump();
    final row = find.byKey(const ValueKey('layout-row-system_block_style'));
    await t.ensureVisible(row);
    await t.tap(row);
    await t.pump();
    final add = find.byKey(const ValueKey('layout-system-pattern-add'));
    await until(t, () => add.evaluate().isNotEmpty);
    await t.ensureVisible(add);
    await t.pump();
    await t.tap(add);
    final result = find.byKey(const ValueKey('system-pattern-result'));
    await until(t, () => result.evaluate().isNotEmpty);
    expect(t.widget<Text>(result).data, '这一行会被识别为系统提示。');
    await t.enterText(
      find.byKey(const ValueKey('system-pattern-sample')),
      '他说≮任务≯',
    );
    await t.pump();
    expect(t.widget<Text>(result).data, '这一行不会被识别。');
    await t.tap(find.byKey(const ValueKey('system-pattern-add')));
    await until(t, () => patterns()?.length == 1);
    expect(patterns(), ['≮.+≯']);
    final chip = find.byKey(const ValueKey(('layout-system-pattern', '≮.+≯')));
    await until(t, () => chip.evaluate().isNotEmpty);
    expect(
      find.descendant(of: chip, matching: find.text('≮……≯')),
      findsOneWidget,
    );
    await t.tap(
      find.descendant(of: chip, matching: find.byTooltip('删除这条规则')).first,
    );
    await until(t, () => patterns() == null);
    expect(t.takeException(), isNull);
  });

  test('手工标注指定样式；自定义规则；真实转换 EPUB 与 KFX', () async {
    final (state, library, root, id) = await book('output');
    final bokai = Platform.environment['EASYPUB_TEST_BOKAI']!;
    try {
      // 规则写进本书。
      final rule = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'rule_options': {
              'op': 'set',
              'value': {
                'system_patterns': ['≮.+≯'],
              },
            },
          },
        },
      });
      expect(await state.production.confirm(rule), true);
      // 手工标注：单行标为面板，两行标为单行提示。
      final session = library.openBlockAnnotations(id);
      int offset(String marker) =>
          utf8.encode(sample.substring(0, sample.indexOf(marker))).length;
      Future<void> mark(String from, String to, String variant) async {
        final snap = await session.list();
        await session.confirm(
          await session.previewAdd(
            snap,
            start: offset(from),
            end: offset(to),
            kind: BlockAnnotationKind.system,
            variant: variant,
          ),
        );
      }

      await mark('【单行却要面板】', '正文二', 'panel');
      await mark('【甲：一】', '结尾', 'note');
      final listed = await session.list();
      expect(listed.annotations.map((a) => a.variant), ['panel', 'note']);
      // 修改：面板改成单行提示。
      final first = listed.annotations.first;
      await session.confirm(
        await session.previewUpdate(
          listed,
          first.id,
          start: first.start,
          end: first.end,
          kind: BlockAnnotationKind.system,
          variant: 'note',
        ),
      );
      expect((await session.list()).annotations.first.variant, 'note');
      await session.confirm(
        await session.previewUpdate(
          await session.list(),
          first.id,
          start: first.start,
          end: first.end,
          kind: BlockAnnotationKind.system,
          variant: 'panel',
        ),
      );
      session.dispose();

      Future<String> convert(String format, String dir) async {
        final s = LegacyConversionSession(state);
        try {
          final plan = await s.preview(
            ConversionRequest(
              books: [id],
              directory: '$root/$dir',
              format: format,
              engine: format == 'KFX' ? bokai : '',
              generateCover: true,
              runChecks: false,
            ),
          );
          final r = (await s.commit(plan, acknowledgeWarnings: true)).single;
          expect(r.complete, true, reason: '$dir $format ${r.detail}');
          return r.path;
        } finally {
          s.dispose();
        }
      }

      final epub = await members(await convert('EPUB', 'out'));
      final xhtml = epub.entries
          .where((e) => e.key.endsWith('.xhtml'))
          .map((e) => e.value)
          .join('\n');
      expect(xhtml, contains('≮任务：清剿妖兽≯'));
      expect('class="blk blk-panel'.allMatches(xhtml).length, 2);
      expect(xhtml, contains('>单行却要面板</p>'));
      expect(xhtml, contains('class="blk blk-note"'));
      expect(xhtml, contains('>【甲：一】</p>'));
      await convert('KFX', 'out');

      // 每个参数取值至少出现一次（V77 已验四个预设），各转一次 KFX 由 Bokai 校验。
      final combos = <Map<String, Map<String, Object>>>[
        {
          'note': {
            ...blockStylePresets['bar']!,
            'border': 'full', 'line': 'double', 'shade': 'medium', //
            'align': 'center', 'size': 100, 'bold': true,
            'brackets': 'remove', 'spacing': 'loose',
          },
          'panel': {
            ...blockStylePresets['titled']!,
            'border': 'left', 'weight': 'thick', 'shade': 'light', //
            'title': 'underline', 'spacing': 'tight',
          },
        },
        {
          'note': {
            ...blockStylePresets['bar']!,
            'border': 'top_bottom', 'weight': 'thin', 'shade': 'none', //
            'key_bold': true,
          },
          'panel': {
            ...blockStylePresets['titled']!,
            'border': 'none', 'shade': 'medium', 'title': 'bold', //
            'align': 'center', 'size': 100, 'bold': true, 'key_bold': false,
            'brackets': 'keep',
          },
        },
      ];
      for (final (i, combo) in combos.indexed) {
        final change = await state.production.previewChanges({
          id: {
            'op': 'patch',
            'fields': {
              'system_styles': {'op': 'set', 'value': combo},
            },
          },
        });
        expect(await state.production.confirm(change), true);
        await convert('KFX', 'combo-$i');
      }
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
