import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/block_annotation_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:easypub_desktop/desk/layout/inset_rule_dialog.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';

const sample =
    '第一章 场景\n正文。\n九阴真经\n天之道，损有余而补不足。\n后文。\n'
    '契约\n立约人以血为誓。\n——灰塔之印\n结尾。\n';

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
 print(json.dumps({n:(z.read(n).decode('utf-8','replace') if n.rsplit('.',1)[-1].lower() in ('opf','xhtml','html','htm','css') else str(len(z.read(n)))) for n in z.namelist()},ensure_ascii=False))
''',
      path,
    ],
    stdoutEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return Map<String, String>.from(jsonDecode(result.stdout as String) as Map);
}

Future<(PrototypeState, LegacyLibraryAdapter, String, String)> book(
  String tag,
) async {
  final root = (await Directory('../artifacts').createTemp('v82-$tag-'))
      .absolute
      .path;
  final state = PrototypeState(settingsDirectory: '$root/settings');
  final library = LegacyLibraryAdapter(backend: state);
  await library.load();
  await library.savePatch({'check_after_import': false});
  final file = File('$root/场景.txt')..writeAsStringSync(sample);
  expect((await library.importFiles([file.path])).single.succeeded, true);
  return (state, library, root, state.currentId);
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

/// V82：场景样式编辑器与分享（LAY-136）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('场景样式预设与 Rust 一致', () async {
    final (state, library, _, _) = await book('presets');
    try {
      final listed = await state.production.productionRequest(
        jsonEncode({'op': 'inset_styles'}),
      );
      final presets = (listed['presets'] as List).cast<Map>();
      expect(
        presets.map((p) => p['id']).toSet(),
        insetStylePresets.keys.toSet(),
      );
      for (final p in presets) {
        final mine = insetStylePresets[p['id']]!;
        expect(p['scene'], mine.$1, reason: '${p['id']}');
        expect(p['name'], mine.$2, reason: '${p['id']}');
        expect(p['style'], mine.$3, reason: '${p['id']}');
      }
      expect(
        (listed['scenes'] as List).map((s) => s['id']).toList(),
        insetTypes.keys.toList(),
      );
      expect(insetPresetOf('classic', insetStylePresets['frame']!.$3), 'frame');
      expect(
        insetPresetOf('classic', {
          ...insetStylePresets['frame']!.$3,
          'drop': true,
        }),
        'custom',
      );
      expect(defaultInsetStyle('chat', 'script')['names'], 'center');
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  testWidgets('排版页：编辑古籍样式并另存为我的场景样式；聊天选剧本对白改的是聊天记录设置', (t) async {
    t.view.physicalSize = const Size(1200, 1500);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      await loadDeskFonts();
      final made = await book('layout');
      (state, library, _, id) = made;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final capture = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: LayoutPage(
              library: library,
              bookId: id,
              navigation: LayoutNavigationGuard(),
              pickPresetFile: () async => null,
              pickPresetDestination: () async => null,
              importCss: () async => null,
              pickStylePack: () async => null,
              pickStylePackDestination: (_) async => null,
            ),
          ),
        ),
      ),
    );
    Future<void> shoot(String name) => t.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final dir = Directory('../artifacts/v82-preview')
        ..createSync(recursive: true);
      await File('${dir.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    Map<String, dynamic> settings() => state.production.settings(id);
    Map? styles() => settings()['inset_styles'] as Map?;
    List saved() =>
        (library.snapshot.value.configuration['inset_style_library']
            as List?) ??
        const [];

    final tabs = find.byKey(const ValueKey('layout-tabs'));
    await until(t, () => tabs.evaluate().isNotEmpty);
    await t.tap(find.descendant(of: tabs, matching: find.text('段落与识别')));
    await t.pump();
    final row = find.byKey(const ValueKey('layout-row-inset_styles'));
    await until(t, () => row.evaluate().isNotEmpty);
    await t.ensureVisible(row);
    await t.tap(row);
    await t.pump();
    final edit = find.byKey(const ValueKey(('layout-inset-edit', 'classic')));
    await until(t, () => edit.evaluate().isNotEmpty);
    await t.ensureVisible(edit);
    await t.pump();
    await t.tap(edit);
    await until(
      t,
      () => find
          .byKey(const ValueKey('inset-editor-border'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const ValueKey('inset-editor-names')), findsNothing);
    for (final (field, label) in [
      ('border', '左线'),
      ('shade', '浅灰'),
      ('drop', '开'),
    ]) {
      final seg = find.byKey(ValueKey('inset-editor-$field'));
      await t.ensureVisible(seg);
      await t.tap(find.descendant(of: seg, matching: find.text(label)));
      await t.pump();
    }
    await t.enterText(find.byKey(const ValueKey('inset-editor-name')), '我的古籍');
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    await shoot('inset-style-editor');
    await t.tap(find.byKey(const ValueKey('inset-editor-apply')));
    await until(
      t,
      () =>
          (styles()?['classic'] as Map?)?['border'] == 'left' &&
          saved().isNotEmpty,
    );
    final classic = Map<String, Object>.from(styles()!['classic'] as Map);
    expect(classic['shade'], 'light');
    expect(classic['drop'], true);
    expect(classic['font'], 'kai', reason: '其余参数沿用文武边栏');
    expect(saved().single, {
      'name': '我的古籍',
      'scene': 'classic',
      'style': classic,
    });
    final mine = find.byKey(
      const ValueKey(('layout-inset-saved', 'classic', '我的古籍')),
    );
    await until(t, () => mine.evaluate().isNotEmpty);
    expect(t.widget<InputChip>(mine).selected, true);
    await shoot('inset-style-rows');
    // 选回内置“文武边栏”：本书不再存改过的古籍参数。
    final frame = find.byKey(
      const ValueKey(('layout-inset-preset', 'classic', 'frame')),
    );
    await t.ensureVisible(frame);
    await t.pump();
    await t.tap(frame);
    await until(t, () => styles() == null);
    // 聊天选“剧本对白”：开着识别时改的是聊天记录设置本身。
    expect(settings()['chat_block_style'], 'window');
    final script = find.byKey(
      const ValueKey(('layout-inset-preset', 'chat', 'script')),
    );
    await t.ensureVisible(script);
    await t.pump();
    await t.tap(script);
    await until(t, () => settings()['chat_block_style'] == 'script');
    expect(styles(), isNull);
    expect(t.takeException(), isNull);
  });

  test('改过的场景样式进入成品；样式包带上场景样式往返；真实转换 EPUB 与 KFX', () async {
    final (state, library, root, id) = await book('output');
    final bokai = Platform.environment['EASYPUB_TEST_BOKAI']!;
    try {
      final session = library.openBlockAnnotations(id);
      int offset(String marker) =>
          utf8.encode(sample.substring(0, sample.indexOf(marker))).length;
      Future<void> mark(String from, String to, String scene) async {
        final snap = await session.list();
        await session.confirm(
          await session.previewAdd(
            snap,
            start: offset(from),
            end: offset(to),
            kind: BlockAnnotationKind.inset,
            variant: scene,
          ),
        );
      }

      await mark('九阴真经', '后文', 'classic');
      await mark('契约', '结尾', 'scroll');
      session.dispose();
      final styles = {
        'classic': {
          ...insetStylePresets['frame']!.$3,
          'ornament': 'lenticular',
          'border': 'full',
          'line': 'dashed',
          'corner': 'round',
        },
        'scroll': {
          ...insetStylePresets['parchment']!.$3,
          'rods': false,
          'shade': 'medium',
          'head': 'big',
        },
      };
      final change = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'inset_styles': {'op': 'set', 'value': styles},
          },
        },
      });
      expect(await state.production.confirm(change), true);
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

      final epub = await members(await convert('EPUB', 'epub'));
      final xhtml = epub.entries
          .where((e) => e.key.endsWith('.xhtml'))
          .map((e) => e.value)
          .join('\n');
      final css = epub.entries
          .where((e) => e.key.endsWith('.css'))
          .map((e) => e.value)
          .join('\n');
      expect(xhtml, contains('<span class="inset-orn">〖</span> 九阴真经'));
      expect(xhtml, isNot(contains('inset-rod')), reason: '去掉卷轴杆');
      expect(
        css,
        contains('.inset-classic { border: 2px dashed; border-radius: 0.4em;'),
      );
      expect(
        css,
        contains(
          '.inset-scroll .inset-inner { padding: 0.4em 0.9em; background-color: #dcdcdc; }',
        ),
      );
      expect(css, isNot(contains('background-image')));
      // 唯一的 PNG 是本次生成的文字封面；不再生成卷轴杆与纸纹。
      expect(epub.keys.where((k) => k.endsWith('.png')), hasLength(1));
      await convert('KFX', 'kfx');

      // 样式包：导出带上场景样式，导入后原样取回。
      final dir = '$root/packs';
      final built = await state.production.productionRequest(
        jsonEncode({
          'op': 'chapter_style',
          'action': 'builtin',
          'id': 'plain',
          'dir': dir,
        }),
      );
      final insets = {
        'chat_block_style': 'channel',
        'letter_block_style': 'plain',
        'styles': styles,
      };
      await state.production.productionRequest(
        jsonEncode({
          'op': 'chapter_style',
          'action': 'export',
          'style': built['style'],
          'blocks': null,
          'insets': insets,
          'path': '$root/我的包.zip',
        }),
      );
      final imported = await state.production.productionRequest(
        jsonEncode({
          'op': 'chapter_style',
          'action': 'import',
          'path': '$root/我的包.zip',
          'dir': dir,
        }),
      );
      expect(imported['insets'], insets);
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('V82b：规则标签与试一试的匹配（与 Rust 同样锚定行首、行尾）', () {
    final rule = {
      'scene': 'scroll',
      'start': RegExp.escape('【契约】'),
      'end': '之印',
      'max_lines': 5,
    };
    expect(insetRuleLabel(rule), '羊皮纸：【契约】 … 之印');
    expect(insetRuleMatch(rule, '前文\n 【契约】 \n立约。\n——灰塔之印\n后文'), (2, 4));
    expect(
      insetRuleMatch({...rule, 'max_lines': 2}, '【契约】\n立约。\n——灰塔之印'),
      isNull,
    );
    expect(insetRuleMatch({...rule, 'end': ''}, '后文\n【契约】'), (2, 2));
    expect(insetRuleMatch(rule, '他说【契约】\n——之印'), isNull, reason: '开头锚定行首');
    expect(
      insetRuleLabel({
        'scene': 'edict',
        'start': '圣旨',
        'end': '',
        'max_lines': 1,
      }),
      '诏书：圣旨（单行）',
    );
  });

  testWidgets('V82b 排版页：添加场景识别规则（试一试）后开启识别，删除规则', (t) async {
    t.view.physicalSize = const Size(1200, 1500);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final made = await book('rules');
      (state, library, _, id) = made;
      // 先关掉识别，验证添加规则会一并开启。
      final change = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'inset_detect': {'op': 'set', 'value': 'off'},
          },
        },
      });
      expect(await state.production.confirm(change), true);
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
    Map<String, dynamic> settings() => state.production.settings(id);
    List rules() =>
        ((settings()['rule_options'] as Map?)?['inset_rules'] as List?) ??
        const [];
    final tabs = find.byKey(const ValueKey('layout-tabs'));
    await until(t, () => tabs.evaluate().isNotEmpty);
    await t.tap(find.descendant(of: tabs, matching: find.text('段落与识别')));
    await t.pump();
    final row = find.byKey(const ValueKey('layout-row-inset_detect'));
    await until(t, () => row.evaluate().isNotEmpty);
    await t.ensureVisible(row);
    await t.tap(row);
    await t.pump();
    final add = find.byKey(const ValueKey('layout-inset-rule-add'));
    await until(t, () => add.evaluate().isNotEmpty);
    await t.ensureVisible(add);
    await t.pump();
    await t.tap(add);
    final result = find.byKey(const ValueKey('inset-rule-result'));
    await until(t, () => result.evaluate().isNotEmpty);
    expect(t.widget<Text>(result).data, '会把第 2–4 行标为“羊皮纸”。');
    await t.enterText(find.byKey(const ValueKey('inset-rule-max')), '2');
    await t.pump();
    expect(t.widget<Text>(result).data, '示例里没有会被标出的段落。');
    await t.enterText(find.byKey(const ValueKey('inset-rule-max')), '0');
    await t.pump();
    expect(t.widget<Text>(result).data, '最多行数为 1–60');
    await t.enterText(find.byKey(const ValueKey('inset-rule-max')), '10');
    await t.tap(find.byKey(const ValueKey(('inset-rule-scene', 'notice'))));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('inset-rule-add')));
    await until(t, () => rules().length == 1);
    expect(rules().single, {
      'scene': 'notice',
      'start': RegExp.escape('【契约】'),
      'end': '之印',
      'max_lines': 10,
    });
    expect(settings()['inset_detect'], 'on', reason: '添加规则时一并开启识别');
    final chip = find.byKey(const ValueKey(('layout-inset-rule', 0)));
    await until(t, () => chip.evaluate().isNotEmpty);
    expect(
      find.descendant(of: chip, matching: find.text('告示：【契约】 … 之印')),
      findsOneWidget,
    );
    await t.tap(
      find.descendant(of: chip, matching: find.byTooltip('删除这条规则')).first,
    );
    await until(t, () => rules().isEmpty);
    expect(t.takeException(), isNull);
  });

  test('V82b 成品：新书默认识别诏书与论坛楼层，真实转换 EPUB 与 KFX', () async {
    final root = (await Directory('../artifacts').createTemp('v82-detect-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final bokai = Platform.environment['EASYPUB_TEST_BOKAI']!;
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/识别.txt')
        ..writeAsStringSync(
          '第一章 圣旨\n正文。\n奉天承运 皇帝诏曰\n着即晋封国公。\n钦此\n圣旨\n赏银百两。\n钦此\n'
          '1楼 楼主\n有人吗？\n\n2楼 路过\n元婴渡劫。\n结尾。\n',
        );
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
      expect(state.production.settings(id)['inset_detect'], 'on');
      Future<String> convert(String format) async {
        final s = LegacyConversionSession(state);
        try {
          final plan = await s.preview(
            ConversionRequest(
              books: [id],
              directory: '$root/$format',
              format: format,
              engine: format == 'KFX' ? bokai : '',
              generateCover: true,
              runChecks: false,
            ),
          );
          final r = (await s.commit(plan, acknowledgeWarnings: true)).single;
          expect(r.complete, true, reason: '$format ${r.detail}');
          return r.path;
        } finally {
          s.dispose();
        }
      }

      final epub = await members(await convert('EPUB'));
      final xhtml = epub.entries
          .where((e) => e.key.endsWith('.xhtml'))
          .map((e) => e.value)
          .join('\n');
      expect('<div class="inset inset-edict">'.allMatches(xhtml).length, 2);
      expect(xhtml, contains('<div class="inset inset-forum">'));
      expect('inset-line inset-floor'.allMatches(xhtml).length, 2);
      await convert('KFX');
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('V82c 章节页：场景标签“逐行设置…”把一行改为回复，再全部改回自动', (t) async {
    t.view.physicalSize = const Size(1440, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    const text =
        '第一章 动态\n正文。\n林小满 @xiaoman · 3 分钟前\n今天的江面。\n沈舟：拍得真好\n转发 12 评论 34 赞 560\n结尾。\n';
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id, root;
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp('v82-roles-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/动态.txt')..writeAsStringSync(text);
      expect((await library.importFiles([file.path])).single.succeeded, true);
      id = state.currentId;
      final session = library.openBlockAnnotations(id);
      int offset(String marker) =>
          utf8.encode(text.substring(0, text.indexOf(marker))).length;
      final snap = await session.list();
      await session.confirm(
        await session.previewAdd(
          snap,
          start: offset('林小满'),
          end: offset('结尾'),
          kind: BlockAnnotationKind.inset,
          variant: 'post',
        ),
      );
      session.dispose();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    List annotations() =>
        (state.production.settings(id)['block_annotations'] as List?) ??
        const [];
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChapterWorkspace(library: library, bookId: id),
        ),
      ),
    );
    final tagId = annotations().single['id'] as String;
    final tag = find.byKey(ValueKey(('block-tag', tagId)));
    await until(t, () => tag.evaluate().isNotEmpty);
    expect(find.text('场景 · 动态 · 手工'), findsOneWidget);
    await t.tap(tag);
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey(('block-tag-roles', tagId))));
    await t.pumpAndSettle();
    // 第 3 行“沈舟：拍得真好”自动判断为正文。
    expect(find.text('自动（正文）'), findsWidgets);
    expect(find.text('自动（转评赞）'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey(('inset-role', 2))));
    await t.pumpAndSettle();
    await t.tap(find.text('回复').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('inset-roles-apply')));
    await until(
      t,
      () => (annotations().single['roles'] as Map?)?['2'] == 'reply',
    );
    await until(
      t,
      () => find.text('场景 · 动态 · 手工 · 逐行 1').evaluate().isNotEmpty,
    );
    // 再打开：全部改回自动。
    await t.tap(tag);
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey(('block-tag-roles', tagId))));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('inset-roles-reset')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('inset-roles-apply')));
    await until(t, () => annotations().single['roles'] == null);
    expect(annotations().single['variant'], 'post');
    expect(t.takeException(), isNull);
  });
}
