import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/layout/kindle_lines.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Kindle 中文断行模型（小预览、排版视图共用）。
void main() {
  List<String> split(
    String text, {
    double width = 10,
    double em = 1,
    double Function(int)? advance,
    double indent = 0,
  }) => [
    for (final l in kindleLines(
      text,
      width: width,
      em: em,
      indent: indent,
      advance: advance ?? (c) => c < 0x80 ? em / 2 : em,
    ))
      text.substring(l.start, l.end),
  ];

  test('与真机预览（已与 KPW5 实机核对）逐行一致：校准样书第 4 章 10 段', () {
    final fixture = jsonDecode(
      File('test/frontend_rewrite/kindle_lines_kpw5_ch4.json')
          .readAsStringSync(),
    ) as Map;
    final width = (fixture['width'] as num).toDouble();
    final adv = (fixture['advance'] as num).toDouble();
    for (final p in fixture['paragraphs'] as List) {
      final expected = (p as List).cast<String>();
      final text = expected.join();
      expect(
        split(text, width: width, em: 63.8, advance: (_) => adv),
        expected,
        reason: text,
      );
    }
  });

  test('行末后置标点只占半个字宽：多排一个标点；放不下时把前一个字带下去', () {
    // 9 个字加逗号：9.5 字宽，放得下。
    expect(split('一二三四五六七八九，十'), ['一二三四五六七八九，', '十']);
    // 10 个字加逗号：逗号不能放在行首，最后一个字随逗号换行。
    expect(split('一二三四五六七八九十，再'), ['一二三四五六七八九', '十，再']);
    // 问号、叹号与句号同类。
    expect(split('一二三四五六七八九？十'), ['一二三四五六七八九？', '十']);
  });

  test('相邻后置标点前一个半宽；段首全角空格后的前置标点半宽', () {
    final lines = kindleLines(
      '甲乙丙丁戊己庚辛壬“。”',
      width: 20,
      em: 1,
      advance: (_) => 1,
    );
    // “。”中句号紧跟闭引号：句号后面的字距减半个字宽。
    expect(lines.single.spacing[10], -.5);
    final indent = kindleLines('　「甲」', width: 20, em: 1, advance: (_) => 1);
    // 全角空格后的“「”去掉左半边：等于全角空格少半个字宽。
    expect(indent.single.spacing.first, -.5);
  });

  test('汉字与西文、数字之间多 0.075 个字宽，行末不计', () {
    final lines = kindleLines(
      '甲1890年',
      width: 20,
      em: 1,
      advance: (c) => c < 0x80 ? .5 : 1,
    );
    expect(lines.single.spacing[0], closeTo(.075, 1e-6));
    expect(lines.single.spacing[1], 0);
    expect(lines.single.spacing[2], 0);
    expect(lines.single.spacing[3], 0);
    expect(lines.single.spacing[4], closeTo(.075, 1e-6));
    expect(lines.single.spacing[5], 0);
  });

  test('禁则：前置标点不在行末，破折号、省略号不拆开，西文单词不拆开', () {
    expect(split('一二三四五六七八九「十」'), ['一二三四五六七八九', '「十」']);
    expect(split('一二三四五六七八九——十'), ['一二三四五六七八', '九——十']);
    // 省略号可以放在行首（KPW5 宋体实测“……您是怎么”开头的一行），两个省略号仍不拆开。
    expect(split('一二三四五六七八九……'), ['一二三四五六七八九', '……']);
    expect(split('一二三四五六七八九十…'), ['一二三四五六七八九十', '…']);
    // 半角字母宽 0.5：“word”放不下整词时整词换行。
    expect(split('一二三四五六七八word'), ['一二三四五六七八', 'word']);
  });

  test('V129 弯引号：不论字体按一个字宽；后置引号在行末半宽；后置标点紧跟前置标点时半宽', () {
    // 宋体类字体引号一个字宽、苹方类约半个字宽：断行结果相同（KPW5 两种字体截图逐字同位）。
    for (final q in [1.0, .49]) {
      double adv(int c) => '“”‘’'.runes.contains(c) ? q : 1;
      // 9 个字 + “？”” = 10 字宽：问号紧跟引号半宽、引号在行末半宽，排得下。
      expect(split('一二三四五六七八九？”再', advance: adv), ['一二三四五六七八九？”', '再']);
      // 行中的后置引号一个字宽（校准样书第四章“走。”岸上有”实测）：版心 9.5 字宽时“九”排不进去。
      expect(split('一二三四五六七”八九十', width: 9.5, advance: adv), [
        '一二三四五六七”八',
        '九十',
      ]);
      // 画出来的宽度与一个字宽一致：字体里的宽度差补进字距。
      final line = kindleLines('甲”乙', width: 20, em: 1, advance: adv).single;
      expect(q + line.spacing[1], closeTo(1, 1e-9));
    }
    // “表情：“检查”：冒号紧跟前置引号，冒号半宽。
    final colon = kindleLines(
      '情：“检',
      width: 20,
      em: 1,
      advance: (_) => 1,
    ).single;
    expect(colon.spacing[1], -.5);
  });

  test('两端对齐：非末行补满版心，末行不补', () {
    final lines = kindleLines(
      '一二三四五六七八九十，再来一次。',
      width: 10.5,
      em: 1,
      advance: (_) => 1,
    );
    expect(lines, hasLength(2));
    final first = lines.first;
    var w = 0.0;
    for (final s in first.spacing) {
      w += 1 + s;
    }
    expect(w, closeTo(10.5, 1e-9));
    // 末行不补两端对齐的字距，只有行末句号压成半宽。
    expect(lines.last.spacing.every((s) => s <= 0), isTrue);
    expect(lines.last.spacing.last, -.5);
  });

  test('按固件二进制分组旧管线，窄字体标点仍按整字候选宽度', () {
    expect(kindleEngineGroupForDevice('voyage'), 'legacy-voyage');
    expect(kindleEngineGroupForDevice('kpw3'), 'legacy-kpw3');
    expect(kindleEngineGroupForDevice('oasis2'), 'legacy-kpw3');
    expect(kindleEngineGroupForDevice('kpw4'), 'legacy-kpw4');
    expect(kindleEngineGroupForDevice('basic10'), 'legacy-kpw4');
    expect(kindleEngineGroupForDevice('kpw5'), 'kpw5');
    expect(kindleEngineGroupForDevice('kpw6'), 'modern');
    final lines = kindleLines(
      '甲乙丙丁九，十',
      width: 5.0,
      em: 1,
      advance: (c) => c == 0xFF0C ? .45 : 1,
      engine: KindleLineEngine.legacyKpw4,
    );
    expect(lines.map((line) => '甲乙丙丁九，十'.substring(line.start, line.end)), [
      '甲乙丙丁',
      '九，十',
    ]);
  });

  test('23 个固件描述符按评分节点插值，并分别乘前后字号', () {
    for (var descriptor = 1; descriptor <= 23; descriptor++) {
      final unit = kindleDescriptorWidth(descriptor, 1, 0);
      expect(unit, greaterThanOrEqualTo(0));
      expect(kindleDescriptorWidth(descriptor, 2, 0), closeTo(unit * 2, 1e-6));
    }
    expect(
      kindleDescriptorPairWidth(19, 2, 16, 24, 0),
      closeTo(
        kindleDescriptorWidth(19, 16, 0) + kindleDescriptorWidth(2, 24, 0),
        1e-6,
      ),
    );
    expect(
      kindleDescriptorPairWidth(19, 2, 24, 16, 0),
      isNot(closeTo(kindleDescriptorPairWidth(19, 2, 16, 24, 0), 1e-6)),
    );
  });

  test('固件字符分类表的标点对使用独立描述符', () {
    expect(kindlePairDescriptor('甲'.runes.single, '，'.runes.single), (
      left: 0,
      right: 0,
    ));
    expect(kindlePairDescriptor('，'.runes.single, '甲'.runes.single), (
      left: 5,
      right: 2,
    ));
    expect(kindlePairDescriptor('。'.runes.single, '甲'.runes.single), (
      left: 4,
      right: 2,
    ));
    expect(kindlePairDescriptor('”'.runes.single, '“'.runes.single), (
      left: 5,
      right: 2,
    ));
    expect(kindlePairDescriptor('）'.runes.single, '（'.runes.single), (
      left: 5,
      right: 2,
    ));
  });

  test('分页状态机遵守孤行、寡行和显式换页', () {
    final paragraph = [
      for (var i = 0; i < 5; i++) const KindleLine(0, 1, <double>[]),
    ];
    final second = [
      for (var i = 0; i < 2; i++) const KindleLine(0, 1, <double>[]),
    ];
    final pages = kindlePaginate(
      [paragraph, second],
      height: 30,
      lineHeight: 10,
      orphans: 2,
      widows: 2,
      breakBefore: const [false, true],
    );
    expect(pages, hasLength(3));
    expect(pages[0].lines.map((line) => line.line), [0, 1, 2]);
    expect(pages[1].lines.map((line) => line.line), [3, 4]);
    expect(pages[2].lines.map((line) => line.paragraph), [1, 1]);
  });

  testWidgets('小预览、排版视图按同一模型断行：Flutter 不再另行折行；首字放大、诗句仍交给 Flutter', (t) async {
    const body = TextStyle(fontSize: 64, height: 1.5);
    const style = PreviewStyle(
      title: body,
      body: body,
      align: TextAlign.justify,
      indent: 0,
      paragraphSpacing: 0,
      titleSpacing: 0,
      padding: EdgeInsets.zero,
    );
    final fixture = jsonDecode(
      File('test/frontend_rewrite/kindle_lines_kpw5_ch4.json')
          .readAsStringSync(),
    ) as Map;
    for (final p in fixture['paragraphs'] as List) {
      final expected = (p as List).cast<String>();
      // 测试字体每个字都是一个字宽（64 像素），与夹具相同。
      final (lines, count) = debugPreviewLines(
        PreviewPiece(expected.join()),
        style,
        1020,
      );
      expect(lines, expected);
      expect(count, expected.length);
    }
    expect(
      debugPreviewLines(
        const PreviewPiece('诗句', kind: 'verse', indent: false),
        style,
        1020,
      ).$1,
      isNull,
    );
    expect(
      debugPreviewLines(
        const PreviewPiece('首字放大', initial: true),
        style,
        1020,
      ).$1,
      isNull,
    );
  });
}
