import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/layout/kindle_lines.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// V124：Kindle 中文断行模型（小预览、排版视图共用）。
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
    // 问号、叹号与句号同类（V124）。
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
    expect(lines.single.spacing, [.075, 0, 0, 0, .075, 0]);
  });

  test('禁则：前置标点不在行末，破折号、省略号不拆开，西文单词不拆开', () {
    expect(split('一二三四五六七八九「十」'), ['一二三四五六七八九', '「十」']);
    expect(split('一二三四五六七八九——十'), ['一二三四五六七八', '九——十']);
    expect(split('一二三四五六七八九……'), ['一二三四五六七八', '九……']);
    // 半角字母宽 0.5：“word”放不下整词时整词换行。
    expect(split('一二三四五六七八word'), ['一二三四五六七八', 'word']);
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
