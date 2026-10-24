import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';
import 'package:easypub_desktop/desk/layout/system_block_look.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

const _lines = [
  '妖兽倒地。',
  '【叮！击杀成功，经验+120】',
  '他收剑入鞘。',
  '叮！',
  '【苍白的正义】',
  '【攻击力：20-25】',
  '【终极圣炎：附带30点伤害】',
  '正文。',
  '【力量：10】 【敏捷：8】',
  '【体质：12】',
  '床前明月光，疑是地上霜。',
  '单独一联不算，孤句也不居中。',
  '白日依山尽，黄河入海流。',
  '——王之涣',
  '结尾。',
];

PreviewStyle _style({Map? styles, String block = 'styled'}) => PreviewStyle(
  title: const TextStyle(fontSize: 20),
  body: const TextStyle(fontSize: 16, height: 1.6),
  align: TextAlign.start,
  indent: 32,
  paragraphSpacing: 6,
  titleSpacing: 12,
  padding: const EdgeInsets.all(12),
  systemBlock: block,
  verseBlock: 'center',
  systemStyles: styles ?? defaultSystemStyles(),
);

/// V104：系统提示分类样式在小预览里照实画（LAY-146）；排版页的识别数量（LAY-147）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('括号、键名、标题、“叮！”的判断与 Rust 相同', () {
    expect(stripSystemBrackets('【力量：10】 【敏捷：8】'), '力量：10　敏捷：8');
    expect(stripSystemBrackets('他看到【提示】'), '他看到【提示】');
    expect(systemKeyEnd('攻击力：20-25'), 3);
    expect(systemKeyEnd('叮！击杀成功：经验'), isNull, reason: '键名里有标点');
    expect(systemKeyEnd('这是一段超过十二个字的很长很长的说明：值'), isNull);
    expect(isSystemTitle('【苍白的正义】'), true);
    expect(isSystemTitle('【攻击力：20-25】'), false);
    for (final ding in ['叮！', '叮~', '叮咚！', ' 叮 ']) {
      expect(isDingLine(ding), true, reason: ding);
    }
    expect(isDingLine('叮！击杀成功'), false);
    // V92 起含白话虚词的 7+7 句子不算诗句（与 Rust 相同）。
    expect(isVerseLine('这份潜在的商机，是我不能忽视的！'), false);
  });

  test('分类样式：一行为单行提示，连续多行（含前面的“叮！”）合成面板；诗句要成联', () {
    final pieces = paginatePreview(
      title: '第一章 开始',
      paragraphs: _lines,
      style: _style(),
      page: const Size(420, 4000),
    ).single;
    final body = pieces.skip(1).toList();
    String describe(PreviewPiece p) =>
        '${p.kind}/${p.role}${p.runStart ? '<' : ''}${p.runEnd ? '>' : ''}'
        '${p.heading ? '#' : ''} ${p.text}';
    expect(body.map(describe).toList(), [
      '/ 妖兽倒地。',
      'system/note<> 【叮！击杀成功，经验+120】', // 提示条保留括号
      '/ 他收剑入鞘。',
      'system/panel<# 叮！', // 标题面板：“叮！”作标题
      'system/panel 苍白的正义', // 去括号
      'system/panel 攻击力：20-25',
      'system/panel> 终极圣炎：附带30点伤害',
      '/ 正文。',
      'system/panel< 力量：10　敏捷：8', // 首行有冒号，不作标题
      'system/panel> 体质：12',
      '/ 床前明月光，疑是地上霜。', // 单句不成联，不算诗句
      '/ 单独一联不算，孤句也不居中。',
      'verse/ 白日依山尽，黄河入海流。',
      'by/ ——王之涣',
      '/ 结尾。',
    ]);

    // 加框模式不分类，也不并入“叮！”（与 Rust 相同）。
    final boxed = paginatePreview(
      title: '第一章 开始',
      paragraphs: _lines,
      style: _style(block: 'box'),
      page: const Size(420, 4000),
    ).single;
    expect(boxed.where((p) => p.role.isNotEmpty), isEmpty);
    expect(boxed.firstWhere((p) => p.text == '叮！').kind, '');
    // 单句诗不居中（V104 前小预览会把它当诗句）。
    expect(
      paginatePreview(
        title: 'T',
        paragraphs: ['床前明月光，疑是地上霜。', '正文。'],
        style: _style(),
        page: const Size(420, 4000),
      ).single.last.kind,
      '',
    );
  });

  test('换样式后预览跟着变：居中强调不去括号，上下双线不作标题', () {
    final pieces = paginatePreview(
      title: 'T',
      paragraphs: _lines,
      style: _style(
        styles: {
          'note': blockStylePresets['center']!,
          'panel': blockStylePresets['rules']!,
        },
      ),
      page: const Size(420, 4000),
    ).single;
    final panel = pieces.where((p) => p.role == 'panel').toList();
    expect(panel.where((p) => p.heading), isEmpty);
    expect(panel[1].text, '【苍白的正义】');
    final note = SystemBlockLook(blockStylePresets['center']!, 16, 1);
    expect(note.center && note.bold && !note.boxed, true);
    final rules = SystemBlockLook(blockStylePresets['rules']!, 16, 1);
    expect(rules.doubleLine && rules.top == 3 && rules.left == 0, true);
  });

  test('分页：块的边框、内边距算进高度，每页不超出版心；跨页切开的面板前后各自不收尾、不起头', () {
    final style = _style();
    const page = Size(260, 230);
    final pages = paginatePreview(
      title: '第一章 开始',
      paragraphs: [
        for (var i = 0; i < 3; i++) ..._lines,
        '【${'长' * 120}】',
        '【${'续' * 60}】',
      ],
      style: style,
      page: page,
    );
    expect(pages.length, greaterThan(3));
    final width = page.width - style.padding.horizontal;
    for (final pieces in pages) {
      expect(
        PreviewPage.contentHeight(pieces, style, width),
        lessThanOrEqualTo(page.height - style.padding.vertical + 0.5),
      );
    }
    final long = [
      for (final pieces in pages)
        ...pieces.where((p) => p.text.contains('长') || p.text.contains('续')),
    ];
    expect(long.length, greaterThan(2), reason: '长面板被切到多页');
    expect(long.first.runStart && !long.first.runEnd, true);
    expect(long.last.runEnd && !long.last.runStart, true);
  });

  testWidgets('小预览能画出各种样式', (t) async {
    final pieces = paginatePreview(
      title: '第一章 开始',
      paragraphs: _lines,
      style: _style(),
      page: const Size(420, 4000),
    ).single;
    for (final styles in [
      defaultSystemStyles(),
      {
        'note': blockStylePresets['center']!,
        'panel': blockStylePresets['rules']!,
      },
    ]) {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            child: PreviewPage(
              pieces: pieces,
              style: _style(styles: styles),
              size: const Size(420, 900),
              paper: Colors.white,
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull);
    }
  });

  testWidgets('排版页“系统提示”下显示本书识别数量（LAY-147）', (t) async {
    t.view.physicalSize = const Size(1100, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v104-counts-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('$root/系统流.txt')
        ..writeAsStringSync('第一章 开始\n${_lines.join('\n')}\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
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
            bookId: state.currentId,
            navigation: LayoutNavigationGuard(),
            pickPresetFile: () async => null,
            pickPresetDestination: () async => null,
            importCss: () async => null,
          ),
        ),
      ),
    );
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 600; i++) {
        await t.pump(const Duration(milliseconds: 20));
        if (ready()) return;
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      fail('界面未就绪');
    }

    final tabs = find.byKey(const ValueKey('layout-tabs'));
    await until(() => tabs.evaluate().isNotEmpty);
    await t.tap(find.descendant(of: tabs, matching: find.text('段落与识别')));
    await t.pump();
    final row = find.byKey(const ValueKey('layout-row-system_block_style'));
    await t.ensureVisible(row);
    await t.tap(row);
    final count = find.byKey(const ValueKey('layout-count-layout.system'));
    await until(() => count.evaluate().isNotEmpty);
    // 单行提示 1 处、面板 2 处；诗词只有带署名的那一联成块（单句不算）。
    expect(t.widget<Text>(count).data, '系统提示 3 处');
    expect(
      t
          .widget<Text>(find.byKey(const ValueKey('layout-count-layout.verse')))
          .data,
      '诗词 1 处',
    );
    // 没有路由时不出“查看位置”。
    expect(find.text('查看位置'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
